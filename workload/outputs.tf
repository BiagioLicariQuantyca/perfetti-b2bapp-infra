output "api_base_url" {
  description = "Base URL of the B2B API for the mobile app."
  value       = "${module.apim.gateway_url}/${var.api_path}/${var.api_version}"
}

output "api_management_name" {
  value = module.apim.name
}

output "function_app_name" {
  value = local.func_api.name
}

output "function_app_hostname" {
  value = local.func_api.default_hostname
}

output "function_app_storage_account_name" {
  value = local.func_api.storage_account_name
}

output "function_hosting" {
  description = "Hosting plan of the Function App: flex or premium."
  value       = var.function_hosting
}

output "principal_ids" {
  description = "Object IDs of the system-assigned identities."
  value = {
    api_management = module.apim.principal_id
    function_app   = local.func_api.principal_id
  }
}
