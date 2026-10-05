variable "name" {
  description = "API Management instance name, computed by the root according to the CAF naming convention. Globally unique (it becomes <name>.azure-api.net)."
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

variable "sku_name" {
  description = "<tier>_<units>, for example Consumption_0 or StandardV2_1. The Consumption tier cannot be changed to or from other tiers on the same instance."
  type        = string
  default     = "Consumption_0"
}

variable "publisher_name" {
  description = "Name of the organization publishing the APIs."
  type        = string
}

variable "publisher_email" {
  description = "Email address receiving service notifications. Prefer a shared mailbox."
  type        = string
}

variable "application_insights_id" {
  description = "Resource ID of the Application Insights receiving request telemetry. null = no telemetry."
  type        = string
  default     = null
}

variable "application_insights_connection_string" {
  description = "Connection string of that Application Insights resource."
  type        = string
  default     = null
  sensitive   = true
}

variable "telemetry_sampling_percentage" {
  description = "Percentage of requests sent to Application Insights (0-100)."
  type        = number
  default     = 100
}
