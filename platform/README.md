# `platform` root

The shared foundations of the solution: monitoring, alerting, the identity of the Azure
Functions and its access to the Key Vault. Application resources (API Management and Function
App) live in the `workload` root and find these resources by name through data sources.

The state is stored in `platform.tfstate`, in the `tfstate-<environment>` container.

## Resources

| Resource | Name (prd) | Managed by |
|---|---|---|
| Log Analytics workspace | `log-b2bapp-prd-weu-001` | Terraform |
| Application Insights | `appi-b2bapp-prd-weu-001` | Terraform |
| Functions managed identity | `id-func-b2bapp-prd-weu-001` | Terraform |
| Daily cap alert | `alert-logcap-b2bapp-prd-weu-001` | Terraform |
| Action group | `ag-b2bapp-prd-weu-001` | Terraform, only when there are recipients |
| Functions access policy on the Key Vault | – | Terraform |
| Key Vault | `key_vault_name` in `envs/<environment>.tfvars` | platform team (read through a data source) |
| Resource group | `resource_group_name` in `envs/<environment>.tfvars` | platform team (read through a data source) |

Every created resource inherits location and tags from the resource group; only the
`description` tag changes.

## Log Analytics workspace

Stores the application telemetry (through Application Insights) and the logs of the solution
resources.

| Setting | Value | Notes |
|---|---|---|
| SKU | `PerGB2018` | pay-as-you-go, billed on ingested volume |
| Retention | 30 days | `log_retention_days` |
| Daily cap | 1 GB | `log_daily_quota_gb`. When the cap is reached, ingestion stops until the next day and the data of that day is lost |
| Workspace shared keys | disabled | Entra ID access only |
| Resource-context access | enabled | whoever can access a resource can read its logs |
| Ingestion and queries from the Internet | allowed | there is no Azure Monitor Private Link Scope; access is still authenticated |

The Key Vault audit logs do not go to this workspace: a diagnostic setting managed by the
platform team sends them to a central security workspace.

## Application Insights

| Setting | Value | Notes |
|---|---|---|
| Model | workspace-based | data is stored in the Log Analytics workspace above |
| Type | `web` | |
| Daily cap | 1 GB, with notifications | `log_daily_quota_gb` |
| IP masking | enabled | client IP addresses are not stored |
| Local authentication | **enabled** | the Functions send telemetry with the connection string (app setting `APPLICATIONINSIGHTS_CONNECTION_STRING`) |
| Ingestion and queries from the Internet | allowed | |

The connection string identifies the resource but is not considered a secret: set it directly
in the app settings, not through Key Vault (with a Key Vault reference the portal can no longer
show the telemetry from the Function App). It is available in the sensitive output
`app_insights_connection_string`.

**To move to Entra ID authentication only:**
1. assign the `Monitoring Metrics Publisher` role on Application Insights to the Functions
   identity;
2. add the app setting `APPLICATIONINSIGHTS_AUTHENTICATION_STRING` =
   `Authorization=AAD;ClientId=<client_id>` (`APPLICATIONINSIGHTS_CONNECTION_STRING` is still
   required);
3. set `local_authentication_enabled = false` in `monitoring.tf`.

## Functions managed identity

`id-func-b2bapp-prd-weu-001` is user-assigned: it exists independently of the Function Apps and
can be shared by them.

- It is attached to the Function App of the `workload` root and is available to the application
  code, for example with the Azure SDK (`DefaultAzureCredential` with its client ID).
- Once role assignments are possible, it is the identity for identity-based connections to the
  storage of the Function App, replacing the connection string.
- Key Vault references in the app settings are resolved by the **system-assigned** identity of
  the Function App, the default behaviour: the `azurerm` resource for Flex Consumption doesn't
  expose the setting that selects another identity. Its Key Vault access is granted in the
  `workload` root.
- It has no federated credentials.
- Access granted today: reading secrets on the Key Vault (see below).
- `client_id` and `principal_id` are in the `identities` output.

## Key Vault

The Key Vault is managed by the platform team. Terraform reads it and adds only the access
policies of the solution identities: network, soft delete, purge protection and logs are outside
this code.

Vault configuration at the time of writing:

| Setting | Value |
|---|---|
| Authorization model | **access policy** |
| SKU | Standard |
| Soft delete | 90 days |
| Purge protection | disabled |
| Public network access | allowed |

### Access managed by Terraform

| Identity | Secret permissions | Where it is defined |
|---|---|---|
| `id-func-b2bapp-prd-weu-001` (Functions, application code) | `Get` | this root (`key_vault.tf`) |
| System-assigned identity of the Function App (Key Vault references) | `Get` | the `workload` root |
| System-assigned identity of API Management | `Get`, `List` | the API Management root, when the instance is created |

Existing access policies (for example those of team members) are not managed by Terraform and
stay unchanged. In code, access policies are defined **only** with the
`azurerm_key_vault_access_policy` resource, never with `access_policy` blocks inside the vault:
the provider does not allow both methods on the same vault.

### Secret management

Secret values **never go through Terraform**, because they would be stored in clear text in the
state. Write them directly to the vault:

```bash
az keyvault secret set --vault-name <key-vault-name> --name <secret-name> --file <file-with-the-value>
```

The file content is stored as is, including the trailing newline that most editors add. For
single-line values remove it first, for example with `tr -d '\r\n' < <file> > <file>.clean`.

Applications read them through **versionless** references, so they always get the latest
version:

| Consumer | Reference | Refresh after a rotation |
|---|---|---|
| Azure Functions | app setting `@Microsoft.KeyVault(SecretUri=https://<key-vault-name>.vault.azure.net/secrets/<secret-name>)` | within 24 hours, or immediately after a change to the app configuration |
| API Management | named value of type **Key vault** with the versionless secret identifier | within 4 hours, or with a manual refresh from the portal |

### Security of the access policy model

With the access policy model, anyone with `Microsoft.KeyVault/vaults/write` on the vault (for
example `Contributor` on the resource group) can grant themselves access to the secrets. The
Contributor role must therefore be limited to the people who manage the solution.

### Moving to the RBAC model

The model recommended by Microsoft is Azure RBAC. Changing the model of an existing vault
**immediately invalidates all access policies** and requires
`Microsoft.Authorization/roleAssignments/write` without conditions. The recommended path is
therefore a **new vault**:

1. create the vault with RBAC and purge protection;
2. assign `Key Vault Secrets User` to the Functions and API Management identities, and
   `Key Vault Secrets Officer` to whoever manages the secrets;
3. copy the secrets, with backup and restore (only possible within the same subscription and
   Azure geography, at most 500 versions per object) or by reading and writing them again;
4. update `key_vault_name` and the references in the app settings and named values;
5. verify that everything works and decommission the old vault.

## Daily cap alert

| Setting | Value |
|---|---|
| Type | scheduled query rule (log search alert) |
| Query | `_LogOperation`, category `Ingestion`, detail `OverQuota` |
| Frequency and window | 1 hour |
| Severity | 2 (Warning) |
| Notifications | through the action group, created only when `alert_email_receivers` is not empty |

Microsoft suggests adding a second alert on a percentage of the cap (for example 90%), to act
before ingestion stops.

## Variables

| Variable | Default | Description |
|---|---|---|
| `subscription_id` | – | subscription of the solution |
| `resource_group_name` | – | existing resource group |
| `environment` | – | `dev`, `tst` or `prd` |
| `workload` | `b2bapp` | workload name in resource names |
| `region_short` | `weu` | region in resource names |
| `instance` | `001` | instance in resource names |
| `key_vault_name` | – | existing Key Vault, in the resource group of the solution |
| `log_retention_days` | 30 | retention of Log Analytics and Application Insights |
| `log_daily_quota_gb` | 1 | daily cap of Log Analytics and Application Insights |
| `alert_email_receivers` | `[]` | email recipients of the alerts |

Per-environment values are in `envs/<environment>.tfvars`, the backend configuration in
`envs/backend-<environment>.hcl`.

## Outputs

| Output | Content |
|---|---|
| `log_analytics_workspace_id` | resource ID of the workspace |
| `app_insights_connection_string` | Application Insights connection string (sensitive) |
| `key_vault_uri` | URI of the Key Vault |
| `identities` | `id`, `client_id` and `principal_id` of the Functions identity |

## Common operations

- **Raise the daily cap during an incident**: increase `log_daily_quota_gb` in the `.tfvars`
  file, then plan and apply. Set it back to the normal value once the incident is closed.
- **Enable notifications**: set `alert_email_receivers`, then plan and apply.
- **Read the connection string**: `terraform output -raw app_insights_connection_string`.
