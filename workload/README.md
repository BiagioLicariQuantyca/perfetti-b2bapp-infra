# `workload` root

The application resources of the solution: the Function App hosting the APIs, API Management
exposing them to the mobile app, and the access of both to the Key Vault. It reads the
resources of the `platform` root by name, so `platform` must be applied first.

The state is stored in `workload.tfstate`, in the `tfstate-<environment>` container.

## Request flow

```
Mobile app ── HTTPS, Authorization: Bearer <token> ──> API Management
   https://apim-b2bapp-prd-weu-001.azure-api.net/b2bapp/v1/<route>
      1. global policy, inbound: validate-jwt (signature, issuer, audience, expiry; 401 if invalid)
      2. API policy, inbound: route to the func-api backend
      3. global policy, backend: limit-concurrency (at most api_max_concurrency requests in
         flight per API, 429 beyond) and forward with a timeout of api_backend_timeout_seconds,
         adding the x-functions-key header (function key read from Key Vault)
          ──> Function App  https://func-api-b2bapp-prd-weu-002.azurewebsites.net/api/<route>
                 functions with AuthorizationLevel.Function (401 without a valid key);
                 the original Authorization header is forwarded unchanged
```

## Resources

| Resource | Name (prd) | Notes |
|---|---|---|
| Storage account | `stapib2bappprdweu002` | dedicated to the Function App |
| Elastic Premium plan | `asp-api-b2bapp-prd-weu-002` | `function_hosting = "premium"` |
| Function App | `func-api-b2bapp-prd-weu-002` | APIs called by the mobile app |
| API Management | `apim-b2bapp-prd-weu-001` | Consumption tier |
| Application Insights logger and diagnostic | – | API Management request telemetry |
| Key Vault access policies | – | Function App (Get) and API Management (Get, List) |
| Backend | `func-api` | points to the Function App |
| Named value | `func-api-key` | function key from Key Vault; created in the second apply |
| API version set and API | `b2bapp`, `b2bapp-v1` | path `/b2bapp/v1` |
| Operations | `GET`, `POST`, `PUT`, `PATCH`, `DELETE` on `/*` | wildcard forwarding |
| Global policy | – | rendered from `policies/global.xml.tftpl`: token validation, concurrency limit, timeout |
| API policy | – | rendered from `policies/api.xml.tftpl`: routing to the backend |
| Metric alert | `alert-apim5xx-b2bapp-prd-weu-001` | API Management 5xx responses |

The Function App resources depend on `function_hosting`:

| `function_hosting` | Environments | Plan | Names | Storage |
|---|---|---|---|---|
| `flex` | dev | Flex Consumption, one app per plan | instance `001`, for example `func-api-b2bapp-dev-weu-001` | `app-package` container for the deployment package |
| `premium` | prd | Elastic Premium | next instance, `002`, for example `func-api-b2bapp-prd-weu-002` | Azure Files content share, created by the platform |

The two sets of names differ so that a new app can be created while the one it replaces still
exists (see Change the hosting plan).

## Settings

### Function App

| Setting | Value | Notes |
|---|---|---|
| Hosting plan | `function_hosting`: `flex` (Flex Consumption) or `premium` (Elastic Premium), Linux | a change creates a new Function App: see Change the hosting plan |
| Runtime | `dotnet-isolated` `10.0` | `function_runtime`; for Python `{ name = "python", version = "3.13" }`. One language per app |
| HTTPS only, minimum TLS | yes, 1.2 | also for the deployment endpoint |
| Basic authentication for deployments | disabled | deployments use Entra ID identities |
| Identities | system-assigned + `id-func-b2bapp-prd-weu-001` | the system-assigned identity resolves Key Vault references; the user-assigned one is available to the code |
| Application Insights | connection string | `APPLICATIONINSIGHTS_CONNECTION_STRING`, set by Terraform |
| App settings | `function_app_settings` | non-secret values and Key Vault references only |

Flex Consumption (`function_hosting = "flex"`): serverless, no deployment slots.

| Setting | Value | Notes |
|---|---|---|
| Instance memory | 2048 MB (1 vCPU) | `function_instance_memory_in_mb`: 512, 2048 or 4096 |
| Always ready instances | 0 | `function_always_ready_http_instances`: with 0 the app scales to zero, with cold starts and no idle cost |
| Maximum instances | 40 | `function_maximum_instance_count` |

Elastic Premium (`function_hosting = "premium"`): always ready instances, no cold starts, billed
for at least one instance even when idle. Settings in `function_premium`:

| Setting | Value | Notes |
|---|---|---|
| `sku_name` | `EP1` (1 vCPU, 3.5 GB) | `EP2` and `EP3` double size and price at each step; changed in place |
| `always_ready_instances` | 1 | 1-20, each billed around the clock |
| `maximum_instance_count` | 20 | maximum burst; extra instances are billed only while allocated |

### Storage account

| Setting | Value | Notes |
|---|---|---|
| Kind, tier, replication | StorageV2, Standard, LRS | can be converted to ZRS on the same account |
| Minimum TLS, HTTPS only, anonymous access | 1.2, yes, disabled | |
| Shared keys | **enabled** | required by the connection string authentication |
| Connections | host storage (`AzureWebJobsStorage`), plus the deployment container (Flex Consumption) or the Azure Files content share (Elastic Premium), all with the connection string | set by Terraform from the account key |
| Lifecycle policies | none | Microsoft warns they could delete function keys |
| Logs | `StorageWrite` of the blob service to Log Analytics | detects any use of the keys outside the Functions host |

The account key is stored in the Terraform state (as for any storage account managed by
Terraform) and in the Function App settings. The state is protected by Entra ID authentication.

### API Management

| Setting | Value | Notes |
|---|---|---|
| Tier | Consumption | billed per call (the first million calls per month are free); 30-second limit per request; cannot change tier on the same instance |
| Publisher | `apim_publisher_name`, `apim_publisher_email` | the email receives service notifications |
| Identity | system-assigned | reads the named values from Key Vault |
| Telemetry | Application Insights, 100% sampling | no client IP addresses and no request or response bodies |
| API | `/b2bapp/v1`, HTTPS only, no subscription key | callers authenticate with a bearer token |
| Token validation | `jwt_validation`, global policy | applies to every API of the instance; `null` = every request is rejected with 401 |
| Concurrency | `api_max_concurrency` = 20 per API | `rate-limit-by-key` isn't available in the Consumption tier |
| Backend timeout | `api_backend_timeout_seconds` = 25 | Microsoft asks for the shortest acceptable value; the Consumption tier ends every request after 30 seconds |
| TLS | TLS 1.2 or later | TLS 1.0, TLS 1.1 and SSL 3.0 are disabled towards clients and backends; cipher suites can't be changed in the Consumption tier |
| Alert | 5xx responses above `alert_api_server_errors_threshold` in 15 minutes | `Requests` metric, `GatewayResponseCodeCategory` = 5xx; notifies `alert_action_group_name` when set |

### Policies

API Management combines policies defined at several scopes: global (all APIs), product, API and
operation. In each section (`inbound`, `backend`, `outbound`, `on-error`) the `<base />` element
decides where the policies of the parent scope run; without it they don't run at all.

| Scope | Content | `<base />` |
|---|---|---|
| Global | token validation (`inbound`), concurrency limit and `forward-request` with timeout (`backend`) | none: the global scope has no parent |
| API `b2bapp-v1` | routing to the `func-api` backend (`inbound`) | **first element of every section** |
| Operations | no policies: they inherit the API policy | – |
| Products | not used: product policies apply only to requests with a subscription key | – |

Placing token validation at the global scope protects every API by default, including future
ones. `<base />` must be the very first element of each section of API and operation policies,
with nothing before it (not even a comment): the Azure Policy built-in *API Management policies
should inherit parent scope policies using `<base />`* checks exactly that. The `backend` section
can contain a single element: at the API scope it is `<base />`, at the global scope it is
`limit-concurrency` wrapping `forward-request`.

The global validation stores the validated token in the `jwt` context variable: per-API checks
(for example on the `scp` scopes) can be added in the API policy after `<base />`, using
`context.Variables["jwt"]`. The portal shows the combined result with **Calculate effective
policy**.

### Compliance notes

| Azure Policy built-in | Status |
|---|---|
| APIs should use only encrypted protocols | compliant (HTTPS only) |
| Secret named values should be stored in Azure Key Vault | compliant |
| Policies should inherit parent scope policies using `<base />` | compliant |
| Direct management endpoint should not be enabled | compliant (not available in the Consumption tier) |
| Calls to API backends should be authenticated | **not compliant**: the rule recognizes only certificates or Authorization credentials, not the `x-functions-key` header. Resolved by the move to the managed identity of API Management (see Future changes) |
| Service should use a SKU that supports virtual networks / should use a virtual network | **not compliant** by design of the Consumption tier; if assigned with the Deny effect it blocks the creation of the instance |

## Deployment procedure

Prerequisites: the `platform` root applied for the same environment, and the permissions listed
in the main README. The commands use `ENV` for the environment (`dev` or `prd`).

### 1. First apply

```bash
ENV=dev
cd workload
terraform init -reconfigure -backend-config=envs/backend-$ENV.hcl
terraform plan -var-file=envs/$ENV.tfvars -out=$ENV.tfplan
terraform apply $ENV.tfplan
```

This creates the Function App, API Management (creation can take several minutes) and the API.
With `function_key_secret_name = null` the Function App rejects the requests forwarded by API
Management; with `jwt_validation = null` API Management answers 401 to every request.

### 2. Manual steps

These values are secrets and never go through Terraform.

**Function key used by API Management.** A dedicated host key, separate from the default
one, can be rotated without affecting other callers. The secret name is
`apim-function-key-<environment>` (`apim-function-key` in production):

```bash
RG=<resource-group>; KV=<key-vault-name>
APP=$(terraform output -raw function_app_name); SECRET=apim-function-key-$ENV   # production: apim-function-key
tmp=$(mktemp)
az functionapp keys set -g "$RG" -n "$APP" --key-type functionKeys --key-name apim --output none
az functionapp keys list -g "$RG" -n "$APP" --query functionKeys.apim -o tsv | tr -d '\r\n' > "$tmp"
az keyvault secret set --vault-name "$KV" --name "$SECRET" --file "$tmp" --output none
rm -f "$tmp"
```

`az keyvault secret set --file` stores the file content as is, so the trailing newline added by
`-o tsv` is removed first: with it, the header sent to the Function App would not match the key.

**Test token signing key** (until Entra External ID is available, and only if it doesn't exist
yet: it is shared by the environments that accept test tokens): run
`tools/test-jwt/create-signing-key.sh --vault <key-vault-name>` and copy the printed modulus.

### 3. Second apply

In `envs/$ENV.tfvars` set the secret name and, only in the environments that accept test tokens
(today dev) and if not set yet, the test token validation:

```hcl
function_key_secret_name = "apim-function-key-dev"

jwt_validation = {
  issuers      = ["urn:b2bapp:test-issuer"]
  audiences    = ["api://b2bapp-test"]
  signing_keys = [{ id = "test-1", n = "<modulus>" }]
}
```

Then plan and apply again. Verify with a test token, from the repository root:

```bash
TOKEN=$(tools/test-jwt/mint-token.sh --vault <key-vault-name>)
curl -i -H "Authorization: Bearer $TOKEN" "$(terraform -chdir=workload output -raw api_base_url)/<route>"
```

## Common operations

- **Add an app setting**: add it to `function_app_settings` in `envs/<environment>.tfvars`,
  then plan and apply. Settings added from the portal or the CLI are removed at the next apply.
- **Add a secret**: write the value to Key Vault
  (`az keyvault secret set --vault-name <kv> --name <name> --file <file>`, with a file without
  a trailing newline: see the Key Vault section of `platform/README.md`), then add an app
  setting with a versionless reference:
  `@Microsoft.KeyVault(SecretUri=https://<kv>.vault.azure.net/secrets/<name>)`. The app picks
  up a new secret version within 24 hours, or immediately after any configuration change.
- **Rotate the function key** without downtime: create a second host key, store it as a new
  version of the same secret, let API Management pick it up, then delete the old key.

  ```bash
  # RG, KV, APP and SECRET as in the manual steps of the deployment procedure
  tmp=$(mktemp)
  az functionapp keys set -g "$RG" -n "$APP" --key-type functionKeys --key-name apim-2 --output none
  az functionapp keys list -g "$RG" -n "$APP" --query '"functionKeys"."apim-2"' -o tsv | tr -d '\r\n' > "$tmp"
  az keyvault secret set --vault-name "$KV" --name "$SECRET" --file "$tmp" --output none
  rm -f "$tmp"
  # Refresh the func-api-key named value from the portal, or wait up to 4 hours, then:
  az functionapp keys delete -g "$RG" -n "$APP" --key-type functionKeys --key-name apim
  ```
- **Tune the backend timeout**: set `api_backend_timeout_seconds` to the shortest value that the
  real response times (Application Insights) allow.
- **Enable alert notifications**: set `alert_action_group_name`, for example to the action group
  of the platform root.
- **Reduce cold starts** on Flex Consumption: set `function_always_ready_http_instances = 1`
  (billed while idle). Elastic Premium always keeps at least one instance ready.
- **Resize the Premium plan**: change `function_premium.sku_name` (`EP1`, `EP2`, `EP3`) or the
  instance counts; the change is applied in place.
- **Change the language** of the Function App: change `function_runtime` only before the first
  code deployment; afterwards create a new Function App.

## Change the hosting plan

A Function App on Linux can't move in place between Flex Consumption and Elastic Premium: changing
`function_hosting` in `envs/<environment>.tfvars` creates a new Function App, with its plan and
storage account, and deletes the previous one. The mobile app is not affected, because it only
calls API Management, but the API answers with errors until the code is deployed and the
function key is stored: plan the switch when the API can be unavailable for a few minutes.

1. Plan and check that it contains only these changes:

   | Action | Resources |
   |---|---|
   | create | plan, Function App, storage account and its diagnostic setting of the new hosting plan |
   | destroy | plan, Function App, storage account (and container) and its diagnostic setting of the previous hosting plan |
   | update in place | `azurerm_api_management_backend.func_api`: URL of the new app |
   | replace | `azurerm_key_vault_access_policy.func_api`: identity of the new app |

2. Apply the saved plan.
3. Create the `apim` host key of the new app and store it in the Key Vault secret named in
   `function_key_secret_name`, with the commands of the manual steps of the deployment procedure
   (`APP` comes from the `function_app_name` output). Then refresh the `func-api-key` named value
   from the portal (API Management → Named values → `func-api-key` → Refresh secret), or wait up to
   4 hours.
4. Deploy the code to the new app (`docs/functions-developer-guide.md`). The app settings are
   already in place; if the portal shows a Key Vault reference in error (the access policy is
   created after the app), restart the app.
5. Call an endpoint through API Management and check the response.

The storage account of the previous app is deleted with its content (function keys, logs of
the host): nothing in it needs to be kept, because the code is deployed again from its package.

## Future changes

### Test tokens → Entra External ID

The complete procedure, including the customer code and the sign-up webhook, is in
`docs/entra-external-id.md`. In short, when the external tenant (tenant ID and subdomain) and the
API app registration (client ID and scopes) are available:

```hcl
jwt_validation = {
  openid_config_url = "https://<subdomain>.ciamlogin.com/<tenant-id>/v2.0/.well-known/openid-configuration"
  audiences         = ["<API client ID>"]
  required_claims   = [{ name = "scp", values = ["<scope>"], match = "any", separator = " " }]
}
```

API Management reads the signing keys and the issuer from the configuration endpoint and
refreshes them every hour. Then delete the `jwt-test-signing-key` secret from Key Vault, the
`tools/test-jwt` folder and `docs/test-tokens.md`.

### Customer code from the token → header for the functions

The functions identify the business partner from a claim of the validated token, for example
`customer_code` (the final name depends on the Entra External ID configuration). The token is
already forwarded unchanged, so the functions can read the claim directly. To read it in one
place and reject tokens without it before they reach the functions, add these elements to
`policies/api.xml.tftpl`, in the `inbound` section **after** `<base />` and before
`set-backend-service`:

```xml
<!-- The global policy stores the validated token in the "jwt" variable -->
<set-variable name="customerCode" value="@(((Jwt)context.Variables[&quot;jwt&quot;]).Claims.GetValueOrDefault(&quot;customer_code&quot;, &quot;&quot;))" />
<choose>
  <when condition="@(string.IsNullOrEmpty((string)context.Variables[&quot;customerCode&quot;]))">
    <return-response>
      <set-status code="403" reason="Forbidden" />
    </return-response>
  </when>
</choose>
<!-- override: a value sent by the client is always replaced -->
<set-header name="X-Customer-Code" exists-action="override">
  <value>@((string)context.Variables[&quot;customerCode&quot;])</value>
</set-header>
```

- Use a header, not a query parameter: the URL and its route stay unchanged, and the value
  doesn't end up in URLs and logs.
- Keep `exists-action="override"`: without it, a client could send its own `X-Customer-Code`.
- The functions read the value only from this header (or from the token), and never fall back
  to a customer code sent by the app.
- Make the claim name a template variable when it is final, so that it is set in the tfvars.
- Test it on dev with `tools/test-jwt/mint-token.sh --claim customer_code=<code>`; a token
  without the claim must get 403. Policy changes go through plan and apply: changes made in the
  portal are overwritten at the next apply.

### Wildcard operations → OpenAPI import

Once the API contract is stable, replace the wildcard operations with the OpenAPI definition
produced by the developers: add an `import` block to `azurerm_api_management_api` with
`content_format = "openapi+json"` (or `openapi` for YAML) and `content_value = file(...)`, and
remove `azurerm_api_management_api_operation.wildcard`. API Management then documents every
operation and only forwards the routes declared in the contract. Breaking changes go to a new
version (`api_version = "v2"`) in the same version set, so that app releases already installed
keep working.

### Storage connection string → managed identity

Requires role assignments (for example Role Based Access Control Administrator on the resource
group). For the identity `id-func-b2bapp-prd-weu-001`:

This applies to Flex Consumption: on Elastic Premium the Azure Files content share still needs
the connection string.

1. assign `Storage Blob Data Owner` and `Storage Table Data Contributor` on the storage account
   (host storage) and `Storage Blob Data Contributor` (deployment container);
2. in the module, set `storage_authentication_type = "UserAssignedIdentity"` with
   `storage_user_assigned_identity_id`, and the app settings `AzureWebJobsStorage__accountName`,
   `AzureWebJobsStorage__credential = "managedidentity"`, `AzureWebJobsStorage__clientId`;
   check the Microsoft note on `AzureWebJobsStorage` for the `azurerm` provider version in use;
3. set `storage_shared_key_enabled = false`.

### Function key → managed identity of API Management

Requires an app registration in Entra ID for the Function App: enable App Service
authentication on the Function App and use the `authentication-managed-identity` policy in
API Management. The function key, the named value and the Key Vault secret can then be removed.

### API Management tier

The Consumption tier cannot be changed on the same instance. To move to Standard v2 (for
example for virtual network integration), create a new instance, apply the same API
configuration to it and switch the clients. Without a custom domain the API URL changes, which
requires a new mobile app release: a custom domain (for example `api.<domain>`, with a DNS record
and a certificate in Key Vault) avoids it.

### Further Function Apps

A scheduled synchronization (for example Commerce Cloud → Salesforce) belongs in a separate
Function App: add another instance of `../modules/function-app-flex` or
`../modules/function-app-premium` (for example `func-sync-b2bapp-prd-weu-001` with storage
`stsyncb2bappprdweu001`) and its Key Vault access policy. Several apps can share one Elastic
Premium plan, but the module creates a plan for each app. Timer triggers on Flex Consumption use
UTC: `WEBSITE_TIME_ZONE` isn't supported.

### Publisher email

Replace `apim_publisher_email` with a shared mailbox; the change is applied in place.

## Variables

| Variable | Default | Description |
|---|---|---|
| `subscription_id`, `resource_group_name`, `environment` | – | context of the solution |
| `workload`, `region_short`, `instance` | `b2bapp`, `weu`, `001` | resource naming |
| `key_vault_name` | – | existing Key Vault |
| `apim_sku_name` | `Consumption_0` | API Management tier |
| `apim_publisher_name`, `apim_publisher_email` | – | API Management publisher |
| `apim_telemetry_sampling_percentage` | 100 | requests sent to Application Insights |
| `function_hosting` | `flex` | hosting plan: `flex` or `premium` |
| `function_runtime` | `dotnet-isolated` `10.0` | language stack |
| `function_instance_memory_in_mb` | 2048 | Flex Consumption: instance memory |
| `function_maximum_instance_count` | 40 | Flex Consumption: maximum on-demand instances |
| `function_always_ready_http_instances` | 0 | Flex Consumption: always ready instances |
| `function_premium` | `{ sku_name = "EP1", always_ready_instances = 1, maximum_instance_count = 20 }` | Elastic Premium: instance size, always ready instances, maximum burst |
| `function_app_settings` | `{}` | application settings |
| `function_key_secret_name` | `null` | Key Vault secret with the function key (second apply) |
| `api_path`, `api_version` | `b2bapp`, `v1` | API URL |
| `api_max_concurrency` | 20 | concurrent requests towards the backend, per API |
| `api_backend_timeout_seconds` | 25 | backend timeout (1-29 seconds) |
| `jwt_validation` | `null` | bearer token validation (global policy) |
| `alert_api_server_errors_threshold` | 5 | 5xx responses in 15 minutes that fire the alert |
| `alert_action_group_name` | `null` | existing action group notified by the alerts |

## Outputs

| Output | Content |
|---|---|
| `api_base_url` | base URL of the API for the mobile app |
| `api_management_name` | API Management instance |
| `function_app_name`, `function_app_hostname` | Function App |
| `function_hosting` | hosting plan of the Function App |
| `function_app_storage_account_name` | storage account of the Function App |
| `principal_ids` | object IDs of the system-assigned identities |
