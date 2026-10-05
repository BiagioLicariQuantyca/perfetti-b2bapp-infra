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

