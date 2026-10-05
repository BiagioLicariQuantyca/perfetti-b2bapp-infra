locals {
  # Cloud Adoption Framework naming: <type>-<workload>-<environment>-<region>-<instance>.
  name_suffix = "${var.workload}-${var.environment}-${var.region_short}-${var.instance}"

  names = {
    log_analytics = "log-${local.name_suffix}"
    app_insights  = "appi-${local.name_suffix}"
    id_func       = "id-func-${local.name_suffix}"
    action_group  = "ag-${local.name_suffix}"
    alert_cap     = "alert-logcap-${local.name_suffix}"
  }

  # Tags are read from the resource group at every plan, so they stay aligned with the
  # company tags; only the description changes, to identify the root.
  tags = merge(data.azurerm_resource_group.this.tags, { description = "B2B App Integration - platform" })

  location = data.azurerm_resource_group.this.location
}
