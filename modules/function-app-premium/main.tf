# Function App on the Elastic Premium plan (Linux), with its own storage account.
# Reference: https://learn.microsoft.com/azure/azure-functions/functions-premium-plan
#
# Microsoft recommends a separate storage account for each function app in production. The
# account serves the host storage (AzureWebJobsStorage: function keys, timer-trigger
# coordination, trigger metadata) and the Azure Files content share used by the plan to scale
# out (WEBSITE_CONTENTAZUREFILECONNECTIONSTRING and WEBSITE_CONTENTSHARE, set by the provider).
# Azure Files doesn't support identity-based connections, so the account keeps shared keys.

locals {
  # .NET apps are built locally and deployed as a zip package that the app runs from. Python
  # apps are built remotely, which requires the build settings instead of the package setting.
  deployment_settings = var.runtime.name == "python" ? {
    SCM_DO_BUILD_DURING_DEPLOYMENT = "true"
    ENABLE_ORYX_BUILD              = "true"
    } : {
    WEBSITE_RUN_FROM_PACKAGE = "1"
  }
}

resource "azurerm_storage_account" "this" {
  name                = var.storage_account_name
  resource_group_name = var.resource_group_name
  location            = var.location
  tags                = var.tags

  account_kind             = "StorageV2"
  account_tier             = "Standard"
  account_replication_type = var.storage_replication_type
  access_tier              = "Hot"

  min_tls_version                  = "TLS1_2"
  https_traffic_only_enabled       = true
  allow_nested_items_to_be_public  = false
  cross_tenant_replication_enabled = false
  public_network_access            = "Enabled"

  # Required by the content share, which supports only the connection string.
  shared_access_key_enabled = true
}

# Write operations on the blob service, to detect any use of the keys outside the Functions
# host. Sent to Log Analytics, outside the storage account itself.
resource "azurerm_monitor_diagnostic_setting" "blob" {
  count = var.log_analytics_workspace_id == null ? 0 : 1

  name                       = "diag-${var.storage_account_name}-blob"
  target_resource_id         = "${azurerm_storage_account.this.id}/blobServices/default"
  log_analytics_workspace_id = var.log_analytics_workspace_id

  enabled_log {
    category = "StorageWrite"
  }
}

# The plan is billed for at least one instance at all times, whether or not functions run.
resource "azurerm_service_plan" "this" {
  name                = var.service_plan_name
  resource_group_name = var.resource_group_name
  location            = var.location
  tags                = var.tags

  os_type                      = "Linux"
  sku_name                     = var.sku_name
  maximum_elastic_worker_count = var.maximum_instance_count
}

resource "azurerm_linux_function_app" "this" {
  name                = var.name
  resource_group_name = var.resource_group_name
  location            = var.location
  service_plan_id     = azurerm_service_plan.this.id
  tags                = var.tags

  functions_extension_version = "~4"
  storage_account_name        = azurerm_storage_account.this.name
  storage_account_access_key  = azurerm_storage_account.this.primary_access_key

  # Logs go to Application Insights: no AzureWebJobsDashboard setting.
  builtin_logging_enabled = false

  https_only                                     = true
  public_network_access_enabled                  = true
  client_certificate_enabled                     = false
  ftp_publish_basic_authentication_enabled       = false
  webdeploy_publish_basic_authentication_enabled = false

  # The system-assigned identity resolves Key Vault references in the app settings (the
  # default behaviour). User-assigned identities are available to the application code.
  identity {
    type         = length(var.user_assigned_identity_ids) > 0 ? "SystemAssigned, UserAssigned" : "SystemAssigned"
    identity_ids = var.user_assigned_identity_ids
  }

  site_config {
    minimum_tls_version                    = "1.2"
    scm_minimum_tls_version                = "1.2"
    ftps_state                             = "Disabled"
    http2_enabled                          = true
    application_insights_connection_string = var.application_insights_connection_string

    # Always ready instances of this app; they also set the minimum size of the plan.
    elastic_instance_minimum = var.always_ready_instances

    application_stack {
      dotnet_version              = var.runtime.name == "dotnet-isolated" ? var.runtime.version : null
      use_dotnet_isolated_runtime = var.runtime.name == "dotnet-isolated" ? true : null
      python_version              = var.runtime.name == "python" ? var.runtime.version : null
    }
  }

  app_settings = merge(var.app_settings, local.deployment_settings)

  lifecycle {
    ignore_changes = [
      # The portal adds this tag to link the app to its Application Insights resource.
      tags["hidden-link: /app-insights-resource-id"],
      # Deployment tools may set it: a remote build configures the app to run from its package.
      app_settings["WEBSITE_RUN_FROM_PACKAGE"],
    ]
  }
}

resource "azurerm_management_lock" "this" {
  count = var.lock == null ? 0 : 1

  name       = "lock-${var.name}"
  scope      = azurerm_linux_function_app.this.id
  lock_level = var.lock.level
  notes      = var.lock.notes
}
