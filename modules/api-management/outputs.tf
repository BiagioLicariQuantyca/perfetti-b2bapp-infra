output "id" {
  value = azurerm_api_management.this.id
}

output "name" {
  value = azurerm_api_management.this.name
}

output "gateway_url" {
  value = azurerm_api_management.this.gateway_url
}

output "principal_id" {
  description = "Object ID of the system-assigned identity (used to grant Key Vault access)."
  value       = azurerm_api_management.this.identity[0].principal_id
}

output "tenant_id" {
  value = azurerm_api_management.this.identity[0].tenant_id
}
