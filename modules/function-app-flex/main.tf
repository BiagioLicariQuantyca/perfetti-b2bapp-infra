# Function App on the Flex Consumption plan, with its own storage account.
# Reference: https://learn.microsoft.com/azure/azure-functions/flex-consumption-plan
#
# Microsoft recommends a separate storage account for each function app in production. The
# account serves two connections: the host storage (AzureWebJobsStorage: function keys,
# timer-trigger coordination, trigger metadata) and the deployment container that holds the
# zip package the app runs from.

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

  # Shared keys stay enabled while the app connects with the storage connection string.
  # Moving to identity-based connections requires role assignments on this account.
  shared_access_key_enabled = var.storage_shared_key_enabled
}

# Deployment container: the platform reads the package from here. Never apply lifecycle
# management policies to this account: they could delete function keys or packages.
resource "azurerm_storage_container" "deployment" {
  name                  = "app-package"
  storage_account_id    = azurerm_storage_account.this.id
  container_access_type = "private"
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

resource "azurerm_service_plan" "this" {
  name                = var.service_plan_name
  resource_group_name = var.resource_group_name
  location            = var.location
  tags                = var.tags

  os_type  = "Linux"
  sku_name = "FC1"
}

resource "azurerm_function_app_flex_consumption" "this" {
  name                = var.name
  resource_group_name = var.resource_group_name
  location            = var.location
  service_plan_id     = azurerm_service_plan.this.id
  tags                = var.tags

  runtime_name           = var.runtime.name
  runtime_version        = var.runtime.version
  instance_memory_in_mb  = var.instance_memory_in_mb
  maximum_instance_count = var.maximum_instance_count

  dynamic "always_ready" {
    for_each = var.always_ready_http_instances > 0 ? [1] : []
    content {
      name           = "http"
      instance_count = var.always_ready_http_instances
    }
  }

  storage_container_type      = "blobContainer"
  storage_container_endpoint  = "${azurerm_storage_account.this.primary_blob_endpoint}${azurerm_storage_container.deployment.name}"
  storage_authentication_type = "StorageAccountConnectionString"
  storage_access_key          = azurerm_storage_account.this.primary_access_key

  https_only                                     = true
  public_network_access_enabled                  = true
  client_certificate_enabled                     = false
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
    http2_enabled                          = true
    application_insights_connection_string = var.application_insights_connection_string
  }

  app_settings = var.app_settings
}

resource "azurerm_management_lock" "this" {
  count = var.lock == null ? 0 : 1

  name       = "lock-${var.name}"
  scope      = azurerm_function_app_flex_consumption.this.id
  lock_level = var.lock.level
  notes      = var.lock.notes
}
