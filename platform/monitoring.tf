# Log Analytics workspace of the solution: it stores the application telemetry collected by
# Application Insights and the logs of the solution resources.
module "log_analytics" {
  source = "../modules/log-analytics-workspace"

  name                = local.names.log_analytics
  resource_group_name = data.azurerm_resource_group.this.name
  location            = local.location
  tags                = local.tags

  retention_in_days = var.log_retention_days
  daily_quota_gb    = var.log_daily_quota_gb

  # The resources communicate over the public network: without an Azure Monitor Private Link
  # Scope (AMPLS), ingestion and queries must be reachable from the Internet. Access is still
  # authenticated with Entra ID.
  internet_ingestion_access_type = "Enabled"
  internet_query_access_type     = "Enabled"
}

module "app_insights" {
  source = "../modules/application-insights"

  name                = local.names.app_insights
  resource_group_name = data.azurerm_resource_group.this.name
  location            = local.location
  tags                = local.tags

  workspace_id         = module.log_analytics.id
  retention_in_days    = var.log_retention_days
  daily_data_cap_in_gb = var.log_daily_quota_gb

  # The Functions send telemetry with the connection string. To move to Entra ID
  # authentication only: Monitoring Metrics Publisher role for the Functions identity,
  # app setting APPLICATIONINSIGHTS_AUTHENTICATION_STRING and this value set to false.
  local_authentication_enabled = true
}
