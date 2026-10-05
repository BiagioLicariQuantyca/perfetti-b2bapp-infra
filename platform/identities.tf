# User-assigned managed identity of the Azure Functions. It exists before the Function App,
# so its Key Vault access is already in place when the app is created and Key Vault
# references resolve immediately (the Function App uses it as `keyVaultReferenceIdentity`).
module "id_func" {
  source = "../modules/user-assigned-identity"

  name                = local.names.id_func
  resource_group_name = data.azurerm_resource_group.this.name
  location            = local.location
  tags                = local.tags
}
