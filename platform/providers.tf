# No credentials in code: the identity comes from the environment (`az login` for a user,
# ARM_* environment variables for a service principal or a pipeline).
provider "azurerm" {
  subscription_id = var.subscription_id

  # Data access to storage accounts with Entra ID instead of access keys.
  storage_use_azuread = true

  features {}
}
