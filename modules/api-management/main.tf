# API Management instance with a system-assigned identity and request telemetry sent to
# Application Insights.
# Reference: https://learn.microsoft.com/azure/well-architected/service-guides/azure-api-management
resource "azurerm_api_management" "this" {
  name                = var.name
  resource_group_name = var.resource_group_name
  location            = var.location
  tags                = var.tags

  sku_name        = var.sku_name
  publisher_name  = var.publisher_name
  publisher_email = var.publisher_email

  # System-assigned: the identity API Management uses to read Key Vault secrets (named values).
  identity {
    type = "SystemAssigned"
  }
}

# Application Insights logger. In the Consumption tier, request logs are available only in
# Application Insights (not in Azure Monitor resource logs).
resource "azurerm_api_management_logger" "app_insights" {
  count = var.application_insights_id == null ? 0 : 1

  name                = "appinsights"
  api_management_name = azurerm_api_management.this.name
  resource_group_name = var.resource_group_name
  resource_id         = var.application_insights_id

  application_insights {
    connection_string = var.application_insights_connection_string
  }
}

# Service-wide diagnostic: no client IP addresses and no request or response bodies, so that
# personal data of the API consumers is not stored in telemetry.
resource "azurerm_api_management_diagnostic" "app_insights" {
  count = var.application_insights_id == null ? 0 : 1

  identifier               = "applicationinsights"
  api_management_name      = azurerm_api_management.this.name
  resource_group_name      = var.resource_group_name
  api_management_logger_id = azurerm_api_management_logger.app_insights[0].id

  sampling_percentage       = var.telemetry_sampling_percentage
  always_log_errors         = true
  log_client_ip             = false
  verbosity                 = "information"
  http_correlation_protocol = "W3C"
}

resource "azurerm_management_lock" "this" {
  count = var.lock == null ? 0 : 1

  name       = "lock-${var.name}"
  scope      = azurerm_api_management.this.id
  lock_level = var.lock.level
  notes      = var.lock.notes
}
