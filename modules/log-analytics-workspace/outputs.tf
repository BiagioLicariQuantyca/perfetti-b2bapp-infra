output "id" {
  value = azurerm_log_analytics_workspace.this.id
}

output "name" {
  value = azurerm_log_analytics_workspace.this.name
}

output "workspace_id" {
  description = "Workspace customer ID (GUID)."
  value       = azurerm_log_analytics_workspace.this.workspace_id
}
