# Function App hosting the APIs called by the mobile app through API Management.
# Additional Function Apps (for example a scheduled synchronization) are further instances
# of the same module, each with its own storage account.
module "func_api" {
  source = "../modules/function-app-flex"

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

  # Identity available to the application code (Azure SDK with its client ID) and, once role
  # assignments are possible, to identity-based storage connections.
  user_assigned_identity_ids = [data.azurerm_user_assigned_identity.func.id]

  app_settings = var.function_app_settings
}
