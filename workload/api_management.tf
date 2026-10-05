module "apim" {
  source = "../modules/api-management"

  name                = local.names.apim
  resource_group_name = data.azurerm_resource_group.this.name
  location            = local.location
  tags                = local.tags

  sku_name        = var.apim_sku_name
  publisher_name  = var.apim_publisher_name
  publisher_email = var.apim_publisher_email

  application_insights_id                = data.azurerm_application_insights.this.id
  application_insights_connection_string = data.azurerm_application_insights.this.connection_string
  telemetry_sampling_percentage          = var.apim_telemetry_sampling_percentage
}
