# Key Vault of the solution: it already exists, it is managed by the platform team and
# Terraform only reads it, without managing its configuration (network, soft delete, purge
# protection, logs). The vault uses the "access policy" authorization model: this root only
# grants access to the identities of the solution and leaves existing access policies intact.
#
# Secret values never go through Terraform (they would be stored in clear text in the
# state): they are written with `az keyvault secret set`.
data "azurerm_key_vault" "this" {
  name                = var.key_vault_name
  resource_group_name = data.azurerm_resource_group.this.name
}

# Azure Functions identity: reads secrets from the application code (Azure SDK).
# "Get" is enough: the code reads one secret at a time and never lists the vault.
resource "azurerm_key_vault_access_policy" "func" {
  key_vault_id = data.azurerm_key_vault.this.id
  tenant_id    = data.azurerm_key_vault.this.tenant_id
  object_id    = module.id_func.principal_id

  secret_permissions = ["Get"]
}
