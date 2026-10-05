# Azure Functions developer guide

How to build, configure and deploy the code of the B2B API Function App. The infrastructure is
described in `workload/README.md`.

## Where the code runs

| Item | Value |
|---|---|
| Function App | `func-api-b2bapp-prd-weu-001` (Flex Consumption, Linux) |
| Resource group, subscription, tenant | see `workload/envs/prd.tfvars` and `bootstrap/envs/prd.env` |
| Runtime | .NET 10, isolated worker model (`function_runtime` in the tfvars) |
| Public URL for clients | `https://apim-b2bapp-prd-weu-001.azure-api.net/b2bapp/v1/<route>` |
| Function URL (not for clients) | `https://func-api-b2bapp-prd-weu-001.azurewebsites.net/api/<route>` |

Clients never call the Function App directly. API Management validates the bearer token, then
forwards the request adding the `x-functions-key` header. A request to
`/b2bapp/v1/<route>` reaches the function whose route is `<route>` under the default `api`
prefix.

## Project setup

**.NET 10, isolated worker model** (the in-process model isn't supported on Flex Consumption):

```bash
func init <project-folder> --worker-runtime dotnet-isolated --target-framework net10.0
```

For .NET 10, Microsoft requires `Microsoft.Azure.Functions.Worker` 2.50.0 or later and the
`Azure.Functions.Sdk` 1.0.0 or later project SDK. With Core Tools v5, `func init --stack dotnet`
targets `net10.0` by default.

**Python** (only if the team chooses it before the first deployment; one language per app):
set `function_runtime = { name = "python", version = "3.13" }` in the tfvars and create the
project with `func init <project-folder> --worker-runtime python`.

## Writing HTTP functions

- Use `AuthorizationLevel.Function`: requests without a valid function key get 401. API
  Management adds the key; never put function keys in the mobile app.
- The `Authorization: Bearer <token>` header is forwarded to the function after API Management
  has validated it. Claims such as `sub` can be read from the token payload.
- Respond quickly:
  - API Management Consumption ends a request after **30 seconds**;
  - an HTTP-triggered function must respond within **230 seconds** in any case;
  - for longer work, accept the request and process it asynchronously.
- API Management forwards at most 20 concurrent requests to the app (`api_max_concurrency`);
  beyond that, callers receive 429 and should retry.
- Write stateless functions: instances are created and removed by the platform.

## Configuration and secrets

- **App settings are managed by Terraform** (`function_app_settings` in
  `workload/envs/<environment>.tfvars`). Settings added from the portal or the CLI are removed
  at the next apply. To add or change one, update the tfvars and run plan and apply (see the
  main README), or ask whoever maintains the infrastructure.
- **Secrets** (for example Salesforce credentials) are stored in Key Vault and referenced from
  an app setting:
  `MY_SECRET = "@Microsoft.KeyVault(SecretUri=https://<key-vault>.vault.azure.net/secrets/<name>)"`.
  The code reads `MY_SECRET` as a normal environment variable. Write the secret value with
  `az keyvault secret set`, never in code, in tfvars or in `local.settings.json` committed to Git.
- **Identity for Azure SDKs**: the app has the user-assigned identity
  `id-func-b2bapp-prd-weu-001`, which can read Key Vault secrets. To use it with
  `DefaultAzureCredential`, pass its client ID (`identities` output of the `platform` root).
- **Telemetry** goes to Application Insights automatically. Don't log personal data (names, VAT
  numbers, tokens).
- **Timer triggers** use **UTC**: `WEBSITE_TIME_ZONE` isn't supported on Flex Consumption.

## Local development

Run the app with Core Tools (`func start`) and the Azurite storage emulator. Keep local settings
in `local.settings.json`, excluded from Git:

```json
{
  "IsEncrypted": false,
  "Values": {
    "AzureWebJobsStorage": "UseDevelopmentStorage=true",
    "FUNCTIONS_WORKER_RUNTIME": "dotnet-isolated"
  }
}
```

## Deployment

Flex Consumption supports only package (zip) deployment, authenticated with Microsoft Entra ID:
publish profiles and basic authentication can't be used. Each team member deploys with their
own account:

```bash
az login --tenant <tenant-id>
az account set --subscription <subscription-id>
```

Then use one of these:

```bash
# Core Tools, from the project folder: builds, packages and deploys
func azure functionapp publish func-api-b2bapp-prd-weu-001

# Azure CLI, with a zip of the build output (for .NET, the content of the publish folder)
az functionapp deployment source config-zip -g <resource-group> \
  -n func-api-b2bapp-prd-weu-001 --src <package.zip>
```

Visual Studio Code (Azure Functions extension, "Deploy to Function App") also works.

A deployment always overwrites the whole app with the new package.

### Rollback

Flex Consumption has no deployment slots. To roll back, deploy the previous package again: keep
every released package (for example as a build artifact or with a Git tag) so that it can be
redeployed. The Azure portal has a **Flex Consumption Deployment** diagnostic (app →
**Diagnose and solve problems**) with the deployment history.

### Continuous deployment (later)

Once a service principal or workload identity is available, deployments can move to GitHub
Actions (OIDC) or Azure Pipelines (workload identity federation), which support Flex
Consumption package deployment natively.

## Testing through API Management

Until Entra External ID is available, call the API with test tokens:

```bash
TOKEN=$(tools/test-jwt/mint-token.sh --vault <key-vault-name>)
curl -H "Authorization: Bearer $TOKEN" https://apim-b2bapp-prd-weu-001.azure-api.net/b2bapp/v1/<route>
```

Test tokens reach the **production** environment and real data: use them carefully.

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| 401 from API Management | missing, expired or invalid token, or token validation not yet configured |
| 401 from the Function App | function key missing: check the `func-api-key` named value and the Key Vault secret |
| 429 | more than `api_max_concurrency` concurrent requests |
| The code reads `@Microsoft.KeyVault(...)` instead of the secret value | Key Vault reference not resolved: check the secret name and the reference status in the app settings of the portal |
| Slow first call | cold start: the app scales to zero when idle |
