# API Function App, on the hosting plan selected by function_hosting. Only one of the two
# modules is created: local.func_api is the one in use, referenced by the API Management
# backend, the Key Vault access policy and the outputs.

module "func_api" {
  source = "../modules/function-app-flex"
  count  = var.function_hosting == "flex" ? 1 : 0

  name                 = local.names.func_api
  service_plan_name    = local.names.plan_func_api
  storage_account_name = local.names.st_func_api
  resource_group_name  = data.azurerm_resource_group.this.name
  location             = local.location
  tags                 = local.tags

  runtime                     = var.function_runtime
  instance_memory_in_mb       = var.function_instance_memory_in_mb
  maximum_instance_count      = var.function_maximum_instance_count
  always_ready_http_instances = var.function_always_ready_http_instances

  log_analytics_workspace_id             = data.azurerm_log_analytics_workspace.this.id
  application_insights_connection_string = data.azurerm_application_insights.this.connection_string

  user_assigned_identity_ids = [data.azurerm_user_assigned_identity.func.id]

  app_settings = var.function_app_settings
}

# The Flex Consumption app existed before the hosting plan became selectable.
moved {
  from = module.func_api
  to   = module.func_api[0]
}

# Its names take the next instance number, because the Premium app is created while the Flex
# Consumption app it replaces still exists.
module "func_api_premium" {
  source = "../modules/function-app-premium"
  count  = var.function_hosting == "premium" ? 1 : 0

  name                 = local.names.func_api_premium
  service_plan_name    = local.names.plan_func_api_premium
  storage_account_name = local.names.st_func_api_premium
  resource_group_name  = data.azurerm_resource_group.this.name
  location             = local.location
  tags                 = local.tags

  runtime                = var.function_runtime
  sku_name               = var.function_premium.sku_name
  always_ready_instances = var.function_premium.always_ready_instances
  maximum_instance_count = var.function_premium.maximum_instance_count

  log_analytics_workspace_id             = data.azurerm_log_analytics_workspace.this.id
  application_insights_connection_string = data.azurerm_application_insights.this.connection_string

  user_assigned_identity_ids = [data.azurerm_user_assigned_identity.func.id]

  app_settings = var.function_app_settings
}

locals {
  func_api = one(concat(module.func_api, module.func_api_premium))
}
