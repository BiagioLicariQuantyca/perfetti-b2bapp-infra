# Terraform state bootstrap

`bootstrap-state.sh` creates, or realigns, the storage account that holds the state of every
Terraform root, and the container of one environment. The storage lives outside Terraform
because the backend must exist before the first `terraform init`.

The script is **idempotent**: running it again reapplies the configuration below without
destroying anything. Before doing anything it checks that the active tenant is the expected one,
and stops otherwise.

## Usage

```bash
az login --tenant <tenant-id>
./bootstrap-state.sh prd   # reads envs/prd.env
```

Environment-specific values are read **only** from `envs/<environment>.env`. Values already set
in the shell are ignored, and the script stops if one is missing.

| Variable | Content |
|---|---|
| `TENANT_ID` | expected tenant, checked before any change |
| `SUBSCRIPTION_ID` | subscription of the solution |
| `RESOURCE_GROUP` | existing resource group that hosts the storage account |
| `STORAGE_ACCOUNT` | name of the state storage account |

At the end, the script prints the backend configuration to save in
`<root>/envs/backend-<environment>.hcl`.

## Resources

| Resource | Name | Notes |
|---|---|---|
| Storage account | `STORAGE_ACCOUNT` from the environment file | StorageV2, Hot tier, `Standard_ZRS` (three synchronous copies in different availability zones of the region) |
| Container | `tfstate-<environment>` | one per environment, anonymous access disabled |
| Lifecycle policy | `expire-noncurrent-state-versions` | deletes non-current state versions |
| Resource lock | `lock-<storage-account>` | `CanNotDelete`, applied only if the identity has `Microsoft.Authorization/locks/write` |

## Storage account settings

| Setting | Value | Effect |
|---|---|---|
| Minimum TLS version | 1.2 | rejects clients using obsolete protocols |
| HTTPS only | enabled | no clear-text traffic |
| Anonymous blob access | disabled | no content readable without authentication |
| Shared key (access keys and key-signed SAS) | **disabled** | data access only with Entra ID; the backend uses `use_azuread_auth = true` |
| Cross-tenant replication | disabled | data cannot be replicated to other tenants |
| Public network access | allowed | reachable from the Internet, but every request needs an authorized Entra ID identity |
| Blob versioning | enabled | every state write keeps the previous version |
| Blob and container soft delete | 30 days | a deleted blob or container can be recovered for 30 days |
| Version lifecycle | deletion after 90 days | limits the growth of historical state versions (containers with the `tfstate-` prefix) |
| Tags | inherited from the resource group | only `description` is overridden |

The state can contain sensitive data (for example resource attributes). This is why access is
limited to Entra ID and governed by data roles.

## Required permissions

| Operation | Permission |
|---|---|
| Create and configure the storage account | `Contributor` on the resource group |
| Read and write the state (`terraform init/plan/apply`) | `Storage Blob Data Contributor` on the storage account or the resource group |
| Apply the lock | `Microsoft.Authorization/locks/write` (for example Owner or User Access Administrator). Without it the script continues and prints a warning |

## State locking and recovery

- **Locking**: the `azurerm` backend takes a lease on the blob during every operation that writes
  the state, so two concurrent runs cannot overwrite each other. If a run is interrupted and
  leaves the lock in place, release it with `terraform force-unlock <lock-id>`, after checking
  that nobody else is working.
- **Previous versions**: list them with the following command.

  ```bash
  az storage blob list --account-name <storage-account> --container-name tfstate-prd \
    --prefix platform.tfstate --include v --auth-mode login \
    --query "[].{version:versionId, current:isCurrentVersion, modified:properties.lastModified}" -o table
  ```

  A version can be restored from the portal: storage account → container → blob →
  **Versions** → **Make current version**.
