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
          ──> Function App  https://func-api-b2bapp-prd-weu-001.azurewebsites.net/api/<route>
                 functions with AuthorizationLevel.Function (401 without a valid key);
                 the original Authorization header is forwarded unchanged
```

## Resources

| Resource | Name (prd) | Notes |
|---|---|---|
| Storage account | `stapib2bappprdweu001` | dedicated to the Function App |
| Deployment container | `app-package` | holds the zip package the app runs from |
| Flex Consumption plan | `asp-api-b2bapp-prd-weu-001` | one app per plan |
| Function App | `func-api-b2bapp-prd-weu-001` | APIs called by the mobile app |
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

## Settings

### Function App

| Setting | Value | Notes |
|---|---|---|
| Hosting plan | Flex Consumption (Linux) | serverless; no deployment slots; cannot be migrated in place to another plan |
| Runtime | `dotnet-isolated` `10.0` | `function_runtime`; for Python `{ name = "python", version = "3.13" }`. One language per app |
| Instance memory | 2048 MB (1 vCPU) | `function_instance_memory_in_mb`: 512, 2048 or 4096 |
| Always ready instances | 0 | `function_always_ready_http_instances`: with 0 the app scales to zero, with cold starts and no idle cost |
| Maximum instances | 40 | `function_maximum_instance_count` |
| HTTPS only, minimum TLS | yes, 1.2 | also for the deployment endpoint |
| Basic authentication for deployments | disabled | Flex deployments use Entra ID identities |
| Identities | system-assigned + `id-func-b2bapp-prd-weu-001` | the system-assigned identity resolves Key Vault references; the user-assigned one is available to the code |
| Application Insights | connection string | `APPLICATIONINSIGHTS_CONNECTION_STRING`, set by Terraform |
| App settings | `function_app_settings` | non-secret values and Key Vault references only |

### Storage account

| Setting | Value | Notes |
|---|---|---|
| Kind, tier, replication | StorageV2, Standard, LRS | can be converted to ZRS on the same account |
| Minimum TLS, HTTPS only, anonymous access | 1.2, yes, disabled | |
| Shared keys | **enabled** | required by the connection string authentication |
| Connections | host storage (`AzureWebJobsStorage`) and deployment storage, both with the connection string | set by Terraform from the account key |
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
APP=func-api-b2bapp-$ENV-weu-001; SECRET=apim-function-key-$ENV   # production: apim-function-key
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

In `envs/$ENV.tfvars` set the secret name and, if not set yet, the test token validation:

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
- **Reduce cold starts**: set `function_always_ready_http_instances = 1` (billed while idle).
- **Change the language** of the Function App: change `function_runtime` only before the first
  code deployment; afterwards create a new Function App.

## Future changes

### Test tokens → Entra External ID

When Perfetti provides the external tenant (tenant ID and subdomain) and the API app
registration (client ID and scopes):

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

### Other hosting plan for the Functions

Flex Consumption apps cannot be migrated in place. Create a new Function App on the target plan,
deploy the code, point the `func-api` backend to it and remove the old app. The mobile app is not
affected, because it only calls API Management.

### API Management tier

The Consumption tier cannot be changed on the same instance. To move to Standard v2 (for
example for virtual network integration), create a new instance, apply the same API
configuration to it and switch the clients. Without a custom domain the API URL changes, which
requires a new mobile app release: a custom domain (for example `api.<domain>`, with a DNS record
and a certificate in Key Vault) avoids it.

### Further Function Apps

A scheduled synchronization (for example Commerce Cloud → Salesforce) belongs in a separate
Function App: add another instance of `../modules/function-app-flex` (for example
`func-sync-b2bapp-prd-weu-001` with storage `stsyncb2bappprdweu001`) and its Key Vault access
policy. Timer triggers on Flex Consumption use UTC: `WEBSITE_TIME_ZONE` isn't supported.

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
| `function_runtime` | `dotnet-isolated` `10.0` | language stack |
| `function_instance_memory_in_mb` | 2048 | instance memory |
| `function_maximum_instance_count` | 40 | maximum on-demand instances |
| `function_always_ready_http_instances` | 0 | always ready instances |
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
| `function_app_storage_account_name` | storage account of the Function App |
| `principal_ids` | object IDs of the system-assigned identities |
