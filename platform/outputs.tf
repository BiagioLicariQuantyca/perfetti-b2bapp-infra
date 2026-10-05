# Outputs for verification and reference. Other roots find these resources by name through
# data sources, without reading this state.
output "log_analytics_workspace_id" {
  value = module.log_analytics.id
}

output "app_insights_connection_string" {
  value     = module.app_insights.connection_string
  sensitive = true
}

output "key_vault_uri" {
  value = data.azurerm_key_vault.this.vault_uri
}

output "identities" {
  value = {
    func = { id = module.id_func.id, client_id = module.id_func.client_id, principal_id = module.id_func.principal_id }
  }
}
