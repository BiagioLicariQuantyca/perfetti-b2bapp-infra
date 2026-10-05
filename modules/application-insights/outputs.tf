output "id" {
  value = azurerm_application_insights.this.id
}

output "name" {
  value = azurerm_application_insights.this.name
}

output "connection_string" {
  value     = azurerm_application_insights.this.connection_string
  sensitive = true
}
