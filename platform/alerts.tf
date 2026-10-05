# Log Analytics daily cap alert: when the cap is reached, ingestion stops until the daily
# reset. Without email recipients the alert exists and is visible in the portal, but sends
# no notifications.
resource "azurerm_monitor_action_group" "this" {
  count = length(var.alert_email_receivers) > 0 ? 1 : 0

  name                = local.names.action_group
  resource_group_name = data.azurerm_resource_group.this.name
  short_name          = substr("ag${var.workload}${var.environment}", 0, 12)
  tags                = local.tags

  dynamic "email_receiver" {
    for_each = toset(var.alert_email_receivers)
    content {
      name                    = replace(email_receiver.value, "/[^a-zA-Z0-9]/", "-")
      email_address           = email_receiver.value
      use_common_alert_schema = true
    }
  }
}

resource "azurerm_monitor_scheduled_query_rules_alert_v2" "log_daily_cap" {
  name                = local.names.alert_cap
  resource_group_name = data.azurerm_resource_group.this.name
  location            = local.location
  tags                = local.tags

  description          = "Workspace ${local.names.log_analytics} reached its daily cap: ingestion is paused until the daily reset."
  severity             = 2
  scopes               = [module.log_analytics.id]
  evaluation_frequency = "PT1H"
  window_duration      = "PT1H"

  # The workspace records the cap being reached in the _LogOperation table.
  criteria {
    query                   = <<-KQL
      _LogOperation
      | where Category =~ "Ingestion"
      | where Detail contains "OverQuota"
    KQL
    time_aggregation_method = "Count"
    operator                = "GreaterThan"
    threshold               = 0
  }

  dynamic "action" {
    for_each = azurerm_monitor_action_group.this
    content {
      action_groups = [action.value.id]
    }
  }
}
