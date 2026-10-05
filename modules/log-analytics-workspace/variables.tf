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

variable "retention_in_days" {
  description = "Retention in days (30-730)."
  type        = number
  default     = 30
}

variable "daily_quota_gb" {
  description = "Daily ingestion cap in GB. -1 = no limit."
  type        = number
  default     = -1
}

variable "internet_ingestion_access_type" {
  description = "Enabled, Disabled or SecuredByPerimeter. Secure default: Disabled (requires AMPLS)."
  type        = string
  default     = "Disabled"
}

variable "internet_query_access_type" {
  description = "Enabled, Disabled or SecuredByPerimeter. Secure default: Disabled (requires AMPLS)."
  type        = string
  default     = "Disabled"
}

variable "local_authentication_enabled" {
  description = "Workspace shared keys. Secure default: disabled, Entra ID only."
  type        = bool
  default     = false
}
