variable "name" {
  description = "Function App name, computed by the root according to the CAF naming convention. Keep it within 32 characters to avoid host ID collisions."
  type        = string

  validation {
    condition     = length(var.name) <= 32
    error_message = "The Function App name must be 32 characters or fewer."
  }
}

variable "service_plan_name" {
  description = "Name of the Flex Consumption plan (one app per plan)."
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
    condition     = contains(["dotnet-isolated", "python", "node", "java", "powershell", "custom"], var.runtime.name)
    error_message = "runtime.name must be one of dotnet-isolated, python, node, java, powershell or custom."
  }
}

variable "instance_memory_in_mb" {
  description = "Instance memory size: 512, 2048 or 4096 MB."
  type        = number
  default     = 2048

  validation {
    condition     = contains([512, 2048, 4096], var.instance_memory_in_mb)
    error_message = "instance_memory_in_mb must be 512, 2048 or 4096."
  }
}

variable "maximum_instance_count" {
  description = "Maximum number of on-demand instances (1-1000). Microsoft advises against values below 40 for HTTP apps."
  type        = number
  default     = 100

  validation {
    condition     = var.maximum_instance_count >= 1 && var.maximum_instance_count <= 1000
    error_message = "maximum_instance_count must be between 1 and 1000."
  }
}

variable "always_ready_http_instances" {
  description = "Always ready instances for the HTTP trigger group. 0 = scale to zero (cold starts, no idle cost)."
  type        = number
  default     = 0
}

variable "storage_replication_type" {
  description = "Replication of the storage account (LRS, ZRS, GRS...)."
  type        = string
  default     = "LRS"
}

variable "storage_shared_key_enabled" {
  description = "Shared key access on the storage account. Must stay true while the app uses the storage connection string."
  type        = bool
  default     = true
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
