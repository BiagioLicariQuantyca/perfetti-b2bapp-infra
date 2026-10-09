locals {
  # Cloud Adoption Framework naming: <type>-<purpose>-<workload>-<environment>-<region>-<instance>.
  name_suffix = "${var.workload}-${var.environment}-${var.region_short}-${var.instance}"
  # Storage accounts allow only lowercase letters and digits (3-24 characters).
  compact_suffix = "${var.workload}${var.environment}${var.region_short}${var.instance}"
  # Next instance number, used by the Premium Function App.
  premium_instance       = format("%03d", tonumber(var.instance) + 1)
  premium_suffix         = "${var.workload}-${var.environment}-${var.region_short}-${local.premium_instance}"
  premium_compact_suffix = "${var.workload}${var.environment}${var.region_short}${local.premium_instance}"

  names = {
    apim                  = "apim-${local.name_suffix}"
    func_api              = "func-api-${local.name_suffix}"
    plan_func_api         = "asp-api-${local.name_suffix}"
    st_func_api           = "stapi${local.compact_suffix}"
    func_api_premium      = "func-api-${local.premium_suffix}"
    plan_func_api_premium = "asp-api-${local.premium_suffix}"
    st_func_api_premium   = "stapi${local.premium_compact_suffix}"
    alert_api_errors      = "alert-apim5xx-${local.name_suffix}"
  }

  # Resources of the platform root, found by name.
  platform_names = {
    log_analytics = "log-${local.name_suffix}"
    app_insights  = "appi-${local.name_suffix}"
    id_func       = "id-func-${local.name_suffix}"
  }

  # Tags are read from the resource group at every plan; only the description changes.
  tags = merge(data.azurerm_resource_group.this.tags, { description = "B2B App Integration - workload" })

  location = data.azurerm_resource_group.this.location
}
