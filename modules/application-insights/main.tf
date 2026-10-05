# Workspace-based Application Insights: telemetry is stored in the Log Analytics workspace.
# Reference: https://learn.microsoft.com/azure/well-architected/service-guides/application-insights
resource "azurerm_application_insights" "this" {
  name                = var.name
  resource_group_name = var.resource_group_name
  location            = var.location
  workspace_id        = var.workspace_id
  application_type    = var.application_type
  tags                = var.tags

  retention_in_days                    = var.retention_in_days
  daily_data_cap_in_gb                 = var.daily_data_cap_in_gb
  daily_data_cap_notifications_enabled = true
  local_authentication_enabled         = var.local_authentication_enabled
  internet_ingestion_enabled           = var.internet_ingestion_enabled
  internet_query_enabled               = var.internet_query_enabled
  ip_masking_enabled                   = true # client IP addresses are not stored
}

resource "azurerm_management_lock" "this" {
  count = var.lock == null ? 0 : 1

  name       = "lock-${var.name}"
  scope      = azurerm_application_insights.this.id
  lock_level = var.lock.level
  notes      = var.lock.notes
}

resource "azurerm_role_assignment" "this" {
  for_each = var.role_assignments

  scope                = azurerm_application_insights.this.id
  role_definition_name = each.value.role_definition_name
  principal_id         = each.value.principal_id
  principal_type       = each.value.principal_type
  description          = each.value.description
}
