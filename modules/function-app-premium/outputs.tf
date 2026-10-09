output "id" {
  value = azurerm_linux_function_app.this.id
}

output "name" {
  value = azurerm_linux_function_app.this.name
}

output "default_hostname" {
  value = azurerm_linux_function_app.this.default_hostname
}

output "principal_id" {
  description = "Object ID of the system-assigned identity (resolves Key Vault references)."
  value       = azurerm_linux_function_app.this.identity[0].principal_id
}

output "storage_account_id" {
  value = azurerm_storage_account.this.id
}

output "storage_account_name" {
  value = azurerm_storage_account.this.name
}
