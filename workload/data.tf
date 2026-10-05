# Existing containers, not managed by Terraform.
data "azurerm_resource_group" "this" {
  name = var.resource_group_name
}

data "azurerm_key_vault" "this" {
  name                = var.key_vault_name
  resource_group_name = data.azurerm_resource_group.this.name
}

# Resources created by the platform root: it must be applied first.
data "azurerm_log_analytics_workspace" "this" {
  name                = local.platform_names.log_analytics
  resource_group_name = data.azurerm_resource_group.this.name
}

data "azurerm_application_insights" "this" {
  name                = local.platform_names.app_insights
  resource_group_name = data.azurerm_resource_group.this.name
}

data "azurerm_user_assigned_identity" "func" {
  name                = local.platform_names.id_func
  resource_group_name = data.azurerm_resource_group.this.name
}
