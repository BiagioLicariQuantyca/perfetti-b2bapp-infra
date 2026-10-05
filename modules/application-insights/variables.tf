variable "name" {
  description = "Resource name, computed by the root according to the CAF naming convention."
  type        = string
}

variable "resource_group_name" {
  description = "Resource group where the resource is created."
  type        = string
}

variable "location" {
  description = "Azure region."
  type        = string
}

variable "tags" {
  description = "Tags to apply (the root inherits them from the resource group)."
  type        = map(string)
  default     = {}
}

variable "lock" {
  description = "Optional resource lock. Requires Microsoft.Authorization/locks/write."
  type = object({
    level = string
    notes = optional(string)
  })
  default = null

  validation {
    condition     = var.lock == null || contains(["CanNotDelete", "ReadOnly"], try(var.lock.level, ""))
    error_message = "lock.level must be CanNotDelete or ReadOnly."
  }
}


variable "role_assignments" {
  description = "Role assignments scoped to this resource. Key = stable logical name."
  type = map(object({
    role_definition_name = string
    principal_id         = string
    principal_type       = optional(string, "ServicePrincipal")
    description          = optional(string)
  }))
  default = {}
}

variable "workspace_id" {
  description = "Resource ID of the Log Analytics workspace (workspace-based Application Insights)."
  type        = string
}

variable "application_type" {
  description = "Application type."
  type        = string
  default     = "web"
}

variable "retention_in_days" {
  description = "Data retention in days."
  type        = number
  default     = 30
}

variable "daily_data_cap_in_gb" {
  description = "Application Insights daily cap, in GB."
  type        = number
  default     = 1
}

variable "local_authentication_enabled" {
  description = "Ingestion with the instrumentation key. Secure default: disabled, Entra ID only (Monitoring Metrics Publisher role on the application identity)."
  type        = bool
  default     = false
}

variable "internet_ingestion_enabled" {
  description = "Ingestion from the Internet. Disable only together with AMPLS."
  type        = bool
  default     = true
}

variable "internet_query_enabled" {
  description = "Queries from the Internet. Disable only together with AMPLS."
  type        = bool
  default     = true
}
