variable "name" {
  description = "Function App name, computed by the root according to the CAF naming convention. Keep it within 32 characters to avoid host ID collisions."
  type        = string

  validation {
    condition     = length(var.name) <= 32
    error_message = "The Function App name must be 32 characters or fewer."
  }
}

variable "service_plan_name" {
  description = "Name of the Elastic Premium plan."
  type        = string
}

variable "storage_account_name" {
  description = "Name of the storage account dedicated to this Function App."
  type        = string
}

variable "resource_group_name" {
  description = "Resource group where the resources are created."
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
  description = "Optional resource lock on the Function App. Requires Microsoft.Authorization/locks/write."
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

variable "runtime" {
  description = "Language stack and version, for example { name = \"dotnet-isolated\", version = \"10.0\" } or { name = \"python\", version = \"3.13\" }."
  type = object({
    name    = string
    version = string
  })

  validation {
    condition     = contains(["dotnet-isolated", "python"], var.runtime.name)
    error_message = "runtime.name must be dotnet-isolated or python."
  }
}

variable "sku_name" {
  description = "Instance size: EP1 (1 vCPU, 3.5 GB), EP2 (2 vCPU, 7 GB) or EP3 (4 vCPU, 14 GB). Can be changed in place."
  type        = string
  default     = "EP1"

  validation {
    condition     = contains(["EP1", "EP2", "EP3"], var.sku_name)
    error_message = "sku_name must be EP1, EP2 or EP3."
  }
}

variable "always_ready_instances" {
  description = "Instances always running and billed, regardless of load (1-20)."
  type        = number
  default     = 1

  validation {
    condition     = var.always_ready_instances >= 1 && var.always_ready_instances <= 20
    error_message = "always_ready_instances must be between 1 and 20."
  }
}

variable "maximum_instance_count" {
  description = "Maximum burst of the plan: instances added under load and billed only while allocated. The regional limit for Linux plans is between 20 and 100."
  type        = number
  default     = 20

  validation {
    condition     = var.maximum_instance_count >= 1 && var.maximum_instance_count <= 100
    error_message = "maximum_instance_count must be between 1 and 100."
  }

  validation {
    condition     = var.maximum_instance_count >= var.always_ready_instances
    error_message = "maximum_instance_count must not be lower than always_ready_instances."
  }
}

variable "storage_replication_type" {
  description = "Replication of the storage account (LRS, ZRS, GRS...)."
  type        = string
  default     = "LRS"
}

variable "log_analytics_workspace_id" {
  description = "Workspace receiving the StorageWrite logs of the blob service. null = no diagnostic setting."
  type        = string
  default     = null
}

variable "application_insights_connection_string" {
  description = "Application Insights connection string (not a secret according to Microsoft, but marked sensitive)."
  type        = string
  sensitive   = true
}

variable "user_assigned_identity_ids" {
  description = "User-assigned managed identities to attach to the Function App."
  type        = list(string)
  default     = []
}

variable "app_settings" {
  description = "Application settings. Secrets must be Key Vault references (@Microsoft.KeyVault(SecretUri=...)), never plain values."
  type        = map(string)
  default     = {}
}
