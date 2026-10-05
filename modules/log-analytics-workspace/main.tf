# Log Analytics workspace: Entra ID authentication only and no public network access by
# default, resource-context access always enabled.
# Reference: https://learn.microsoft.com/azure/well-architected/service-guides/azure-log-analytics
resource "azurerm_log_analytics_workspace" "this" {
  name                = var.name
  resource_group_name = var.resource_group_name
  location            = var.location
  sku                 = "PerGB2018"
  tags                = var.tags

  retention_in_days = var.retention_in_days
  daily_quota_gb    = var.daily_quota_gb

  local_authentication_enabled    = var.local_authentication_enabled
  allow_resource_only_permissions = true
  internet_ingestion_access_type  = var.internet_ingestion_access_type
  internet_query_access_type      = var.internet_query_access_type
}

resource "azurerm_management_lock" "this" {
  count = var.lock == null ? 0 : 1

  name       = "lock-${var.name}"
  scope      = azurerm_log_analytics_workspace.this.id
  lock_level = var.lock.level
  notes      = var.lock.notes
}

resource "azurerm_role_assignment" "this" {
  for_each = var.role_assignments

  scope                = azurerm_log_analytics_workspace.this.id
  role_definition_name = each.value.role_definition_name
  principal_id         = each.value.principal_id
  principal_type       = each.value.principal_type
  description          = each.value.description
}
