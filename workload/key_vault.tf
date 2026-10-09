# Access of the workload identities to the Key Vault (access policy model). Existing access
# policies are not managed here and stay unchanged.

# Function App system-assigned identity: resolves Key Vault references in the app settings.
resource "azurerm_key_vault_access_policy" "func_api" {
  key_vault_id = data.azurerm_key_vault.this.id
  tenant_id    = data.azurerm_key_vault.this.tenant_id
  object_id    = local.func_api.principal_id

  secret_permissions = ["Get"]
}

# API Management system-assigned identity: reads named values of type Key vault. Microsoft
# documents Get and List as the required secret permissions.
resource "azurerm_key_vault_access_policy" "apim" {
  key_vault_id = data.azurerm_key_vault.this.id
  tenant_id    = data.azurerm_key_vault.this.tenant_id
  object_id    = module.apim.principal_id

  secret_permissions = ["Get", "List"]
}
