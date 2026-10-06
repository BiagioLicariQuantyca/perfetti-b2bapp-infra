# Alert on API Management server errors (5xx returned to the callers), based on the Requests
# platform metric, available in every tier. Without an action group the alert exists and is
# visible in the portal, but sends no notifications.
data "azurerm_monitor_action_group" "alerts" {
  count = var.alert_action_group_name == null ? 0 : 1

  name                = var.alert_action_group_name
  resource_group_name = data.azurerm_resource_group.this.name
}

resource "azurerm_monitor_metric_alert" "api_server_errors" {
  name                = local.names.alert_api_errors
  resource_group_name = data.azurerm_resource_group.this.name
  scopes              = [module.apim.id]
  tags                = local.tags

  description = "API Management ${local.names.apim} returned more than ${var.alert_api_server_errors_threshold} responses with a 5xx status in 15 minutes."
  severity    = 2
  frequency   = "PT5M"
  window_size = "PT15M"

  criteria {
    metric_namespace = "Microsoft.ApiManagement/service"
    metric_name      = "Requests"
    aggregation      = "Total"
    operator         = "GreaterThan"
    threshold        = var.alert_api_server_errors_threshold

    dimension {
      name     = "GatewayResponseCodeCategory"
      operator = "Include"
      values   = ["5xx"]
    }
  }

  dynamic "action" {
    for_each = data.azurerm_monitor_action_group.alerts
    content {
      action_group_id = action.value.id
    }
  }
}
