# Modules

One module per resource type, used by the roots. They require Terraform `>= 1.15, < 2.0` and
the `azurerm` provider `>= 5.8, < 6.0`.

## Conventions

- **Secure by default.** Every variable defaults to the value recommended by the
  [Well-Architected Framework](https://learn.microsoft.com/azure/well-architected/) and by the
  security baseline of the service. When a root departs from a default, it declares it
  explicitly and explains it in a comment.
- **Fixed constraints.** Settings that must never change are not exposed as variables.
- **Common interface.** All modules accept `name`, `resource_group_name`, `location`, `tags`
  and `lock`. Where useful they also accept `role_assignments`, scoped to the resource.
- **Names decided by the root.** Modules do not compute names: the root passes them in, using
  the Cloud Adoption Framework naming convention.
- **Independent of who runs Terraform.** No module grants access to the identity running the
  plan (no `azurerm_client_config` for permissions).
- **Optional lock.** `lock = { level = "CanNotDelete" | "ReadOnly", notes = "..." }` creates a
  management lock and requires `Microsoft.Authorization/locks/write`.
- **Optional role assignments.** `role_assignments` requires
  `Microsoft.Authorization/roleAssignments/write` (for example Role Based Access Control
  Administrator).

## `log-analytics-workspace`

Log Analytics workspace, with optional lock and role assignments.

| Setting | Value | Kind |
|---|---|---|
| SKU | `PerGB2018` (pay-as-you-go by volume) | fixed |
| Resource-context access (`allow_resource_only_permissions`) | enabled: whoever can access a resource can read its logs without access to the whole workspace | fixed |
| `local_authentication_enabled` | `false`: no shared keys, Entra ID only | default |
| `internet_ingestion_access_type` / `internet_query_access_type` | `Disabled`: requires an Azure Monitor Private Link Scope (AMPLS) | default |
| `retention_in_days` | 30 (allowed values 30-730) | default |
| `daily_quota_gb` | `-1` (no limit) | default |

Outputs: `id`, `name`, `workspace_id` (customer ID).

## `application-insights`

**Workspace-based** Application Insights: telemetry is stored in the given Log Analytics
workspace. Optional lock and role assignments.

| Setting | Value | Kind |
|---|---|---|
| `workspace_id` | required | – |
| Notifications when the daily cap is reached | enabled | fixed |
| IP masking | enabled: client IP addresses are not stored | fixed |
| `local_authentication_enabled` | `false`: ingestion with Entra ID only (`Monitoring Metrics Publisher` role on the application identity) | default |
| `internet_ingestion_enabled` / `internet_query_enabled` | `true`: disable only together with AMPLS | default |
| `application_type` | `web` | default |
| `retention_in_days` | 30 | default |
| `daily_data_cap_in_gb` | 1 | default |

Outputs: `id`, `name`, `connection_string` (sensitive).

## `user-assigned-identity`

User-assigned managed identity, with optional lock. Access for the identity is granted on the
target resources, through role assignments or access policies, not in the module.

The module **does not create federated credentials**: allowing a system outside Azure to obtain
tokens for the identity must be an explicit decision.

Outputs: `id`, `name`, `principal_id` (object ID, used to grant access), `client_id` (used by
applications).

## `function-app-flex`

Function App on the Flex Consumption plan, with a dedicated storage account (as Microsoft
recommends for production), the deployment container and the storage logs. Optional lock on the
Function App.

| Setting | Value | Kind |
|---|---|---|
| Plan | Flex Consumption (`FC1`, Linux), one app per plan | fixed |
| Storage authentication | connection string from the account key, for both host storage and deployment container | fixed |
| Storage account | StorageV2, TLS 1.2, HTTPS only, no anonymous access, no cross-tenant replication | fixed |
| `storage_replication_type` | `LRS` | default |
| `storage_shared_key_enabled` | `true`: required by the connection string authentication | default |
| Deployment container | `app-package`, private | fixed |
| Storage logs | `StorageWrite` of the blob service to `log_analytics_workspace_id` | optional |
| HTTPS only, minimum TLS (site and deployment endpoint) | yes, 1.2 | fixed |
| Basic authentication for deployments | disabled | fixed |
| Identity | system-assigned (Key Vault references) plus `user_assigned_identity_ids` | fixed / input |
| `runtime` | required, for example `dotnet-isolated` `10.0` or `python` `3.13` | input |
| `instance_memory_in_mb` | 2048 (512, 2048 or 4096) | default |
| `maximum_instance_count` | 100 (1-1000) | default |
| `always_ready_http_instances` | 0 | default |
| `name` | at most 32 characters, to avoid host ID collisions | validated |
| Tag `hidden-link: /app-insights-resource-id` | added by the portal to link the app to Application Insights | ignored |

Outputs: `id`, `name`, `default_hostname`, `principal_id` (system-assigned identity),
`storage_account_id`, `storage_account_name`.

## `function-app-premium`

Function App on the Elastic Premium plan (Linux), with a dedicated storage account and the
storage logs. Optional lock on the Function App. Same interface and outputs as
`function-app-flex`, so a root can switch between the two.

| Setting | Value | Kind |
|---|---|---|
| Plan | Elastic Premium, Linux | fixed |
| `sku_name` | `EP1` (1 vCPU, 3.5 GB); `EP2` and `EP3` double size and price at each step; can be changed in place | default |
| `always_ready_instances` | 1 (1-20): instances always running and billed, regardless of load; they also set the minimum size of the plan | default |
| `maximum_instance_count` | 20 (1-100): maximum burst of the plan, instances billed only while allocated | default |
| Storage authentication | connection string from the account key, for the host storage and the Azure Files content share (set by the provider) | fixed |
| Storage account | StorageV2, TLS 1.2, HTTPS only, no anonymous access, no cross-tenant replication, shared keys enabled (the content share doesn't support identity-based connections) | fixed |
| `storage_replication_type` | `LRS` | default |
| Storage logs | `StorageWrite` of the blob service to `log_analytics_workspace_id` | optional |
| Deployment | `.NET`: `WEBSITE_RUN_FROM_PACKAGE = 1` (the app runs from the zip package); Python: remote build (`SCM_DO_BUILD_DURING_DEPLOYMENT`, `ENABLE_ORYX_BUILD`) | fixed |
| `WEBSITE_RUN_FROM_PACKAGE` | changes made by the deployment tools | ignored |
| HTTPS only, minimum TLS (site and deployment endpoint), FTP | yes, 1.2, disabled | fixed |
| Basic authentication for deployments | disabled | fixed |
| Built-in logging (`AzureWebJobsDashboard`) | disabled: logs go to Application Insights | fixed |
| Identity | system-assigned (Key Vault references) plus `user_assigned_identity_ids` | fixed / input |
| `runtime` | required: `dotnet-isolated` (for example `10.0`) or `python` (for example `3.13`) | input |
| `name` | at most 32 characters, to avoid host ID collisions | validated |
| Tag `hidden-link: /app-insights-resource-id` | added by the portal to link the app to Application Insights | ignored |

A Premium plan is billed for at least one instance at all times. A Function App can't be moved
in place between a Flex Consumption plan and a Premium plan on Linux: the switch creates a new
app.

Outputs: `id`, `name`, `default_hostname`, `principal_id` (system-assigned identity),
`storage_account_id`, `storage_account_name`.

## `api-management`

API Management instance with a system-assigned identity and request telemetry in Application
Insights. Optional lock.

| Setting | Value | Kind |
|---|---|---|
| `sku_name` | `Consumption_0` | default |
| Identity | system-assigned: reads named values of type Key vault | fixed |
| Telemetry | Application Insights logger and service diagnostic, created when `application_insights_id` is set | optional |
| Diagnostic | no client IP addresses, no request or response bodies, errors always logged, W3C correlation | fixed |
| `telemetry_sampling_percentage` | 100 | default |

Outputs: `id`, `name`, `gateway_url`, `principal_id`, `tenant_id`.
