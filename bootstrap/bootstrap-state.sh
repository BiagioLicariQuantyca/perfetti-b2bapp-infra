#!/usr/bin/env bash
# Bootstrap of the Terraform state storage - B2B App Integration.
#
# Creates (or realigns) the storage account that holds the Terraform state and the
# container of one environment. It lives outside Terraform to solve the chicken-and-egg
# problem: the backend must exist before the first `terraform init`.
#
# Idempotent: running it again reapplies the configuration without destroying anything.
#
# Usage:
#   az login --tenant <tenant-id>       # personal account or service principal
#   ./bootstrap-state.sh <environment>  # e.g. ./bootstrap-state.sh prd
#
# Environment-specific values are read only from envs/<environment>.env
# (TENANT_ID, SUBSCRIPTION_ID, RESOURCE_GROUP, STORAGE_ACCOUNT).
#
# Permissions required on the identity running it:
#   - Contributor on the resource group (control plane)
#   - Storage Blob Data Contributor on the storage account or resource group (to use the state)

set -euo pipefail

ENVIRONMENT="${1:-}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/envs/$ENVIRONMENT.env"

if [[ -z "$ENVIRONMENT" ]]; then
  echo "Usage: $0 <environment>   (reads envs/<environment>.env)" >&2
  exit 1
fi
if [[ ! -f "$ENV_FILE" ]]; then
  echo "Environment file not found: $ENV_FILE" >&2
  exit 1
fi

# The environment file is the only source of these values: anything already set in the
# shell is discarded, so a forgotten export can never redirect the script elsewhere.
unset TENANT_ID SUBSCRIPTION_ID RESOURCE_GROUP STORAGE_ACCOUNT
# shellcheck source=/dev/null
source "$ENV_FILE"
: "${TENANT_ID:?TENANT_ID is missing in $ENV_FILE}"
: "${SUBSCRIPTION_ID:?SUBSCRIPTION_ID is missing in $ENV_FILE}"
: "${RESOURCE_GROUP:?RESOURCE_GROUP is missing in $ENV_FILE}"
: "${STORAGE_ACCOUNT:?STORAGE_ACCOUNT is missing in $ENV_FILE}"

# Data protection settings, identical for every environment.
SKU="Standard_ZRS"
RETENTION_DAYS=30
VERSION_RETENTION_DAYS=90
CONTAINER="tfstate-$ENVIRONMENT"
DESCRIPTION="B2B App Integration - Terraform state"

log() { printf '\n==> %s\n' "$*"; }

# --- Context guard: never run against the wrong tenant or subscription ---
log "Checking Azure context"
current_tenant=$(az account show --query tenantId -o tsv)
if [[ "$current_tenant" != "$TENANT_ID" ]]; then
  echo "Active tenant is $current_tenant, expected $TENANT_ID. Aborting." >&2
  exit 1
fi
az account set --subscription "$SUBSCRIPTION_ID"
echo "Identity: $(az account show --query user.name -o tsv) ($(az account show --query user.type -o tsv))"

# --- Tags inherited from the resource group, overriding only the description ---
log "Reading tags and location of resource group $RESOURCE_GROUP"
location=$(az group show -n "$RESOURCE_GROUP" --query location -o tsv)
# while-read instead of mapfile: the system bash on macOS is 3.2
tags=()
while IFS= read -r tag; do tags+=("$tag"); done < <(
  az group show -n "$RESOURCE_GROUP" --query tags -o json \
    | jq -r --arg d "$DESCRIPTION" '. + {description: $d} | to_entries[] | "\(.key)=\(.value)"'
)

# --- Storage account ---
security_flags=(
  --min-tls-version TLS1_2
  --https-only true
  --allow-blob-public-access false
  --allow-shared-key-access false
  --allow-cross-tenant-replication false
  --public-network-access Enabled
  --default-action Allow
)

if az storage account show -n "$STORAGE_ACCOUNT" -g "$RESOURCE_GROUP" &>/dev/null; then
  log "Storage account $STORAGE_ACCOUNT exists: realigning configuration and tags"
  az storage account update -n "$STORAGE_ACCOUNT" -g "$RESOURCE_GROUP" \
    "${security_flags[@]}" --tags "${tags[@]}" --output none
else
  log "Creating storage account $STORAGE_ACCOUNT ($SKU, $location)"
  az storage account create -n "$STORAGE_ACCOUNT" -g "$RESOURCE_GROUP" -l "$location" \
    --sku "$SKU" --kind StorageV2 --access-tier Hot \
    "${security_flags[@]}" --tags "${tags[@]}" --output none
fi

# --- State protection: versioning and soft delete ---
log "Versioning and soft delete ($RETENTION_DAYS days)"
az storage account blob-service-properties update \
  --account-name "$STORAGE_ACCOUNT" -g "$RESOURCE_GROUP" \
  --enable-versioning true \
  --enable-delete-retention true --delete-retention-days "$RETENTION_DAYS" \
  --enable-container-delete-retention true --container-delete-retention-days "$RETENTION_DAYS" \
  --output none

# --- Non-current versions never expire on their own: delete them after VERSION_RETENTION_DAYS ---
log "Lifecycle policy: non-current versions deleted after $VERSION_RETENTION_DAYS days"
policy_file="$(mktemp)"
trap 'rm -f "$policy_file"' EXIT
cat > "$policy_file" <<POLICY
{
  "rules": [
    {
      "name": "expire-noncurrent-state-versions",
      "enabled": true,
      "type": "Lifecycle",
      "definition": {
        "filters": { "blobTypes": ["blockBlob"], "prefixMatch": ["tfstate-"] },
        "actions": { "version": { "delete": { "daysAfterCreationGreaterThan": $VERSION_RETENTION_DAYS } } }
      }
    }
  ]
}
POLICY
az storage account management-policy create --account-name "$STORAGE_ACCOUNT" \
  -g "$RESOURCE_GROUP" --policy @"$policy_file" --output none

# --- Environment container, created through ARM (no data-plane role needed) ---
log "Container $CONTAINER"
az storage container-rm create --storage-account "$STORAGE_ACCOUNT" -g "$RESOURCE_GROUP" \
  -n "$CONTAINER" --public-access off --output none

# --- CanNotDelete lock: requires Microsoft.Authorization/locks/write ---
log "Resource lock"
if az lock create -n "lock-$STORAGE_ACCOUNT" --lock-type CanNotDelete \
     -g "$RESOURCE_GROUP" --resource "$STORAGE_ACCOUNT" \
     --resource-type Microsoft.Storage/storageAccounts --output none 2>/dev/null; then
  echo "CanNotDelete lock applied."
else
  echo "WARNING: lock not applied. It requires Microsoft.Authorization/locks/write (e.g. Owner or User Access Administrator)."
fi

log "Done. Backend configuration for <root>/envs/backend-$ENVIRONMENT.hcl:"
cat <<EOF

resource_group_name  = "$RESOURCE_GROUP"
storage_account_name = "$STORAGE_ACCOUNT"
container_name       = "$CONTAINER"
use_azuread_auth     = true
EOF
