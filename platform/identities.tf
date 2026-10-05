# User-assigned managed identity of the Azure Functions, independent of their lifecycle. It is
# available to the application code (Azure SDK) and, once role assignments are possible, to
# identity-based storage connections. Key Vault references in the app settings are resolved by
# the system-assigned identity of each Function App (see the workload root).
module "id_func" {
  source = "../modules/user-assigned-identity"

  name                = local.names.id_func
  resource_group_name = data.azurerm_resource_group.this.name
  location            = local.location
  tags                = local.tags
}
