variable "subscription_id" {
  description = "Subscription of the solution."
  type        = string
}

variable "resource_group_name" {
  description = "Resource group of the solution, existing and not managed by Terraform."
  type        = string
}

variable "environment" {
  description = "Environment, used in resource names."
  type        = string

  validation {
    condition     = contains(["dev", "tst", "prd"], var.environment)
    error_message = "environment must be dev, tst or prd."
  }
}

variable "workload" {
  description = "Workload name used in resource names."
  type        = string
  default     = "b2bapp"
}

variable "region_short" {
  description = "Region abbreviation used in resource names."
  type        = string
  default     = "weu"
}

variable "instance" {
  description = "Instance number used in resource names."
  type        = string
  default     = "001"
}

variable "key_vault_name" {
  description = "Existing Key Vault of the solution (access policy authorization model), in the resource group of the solution."
  type        = string
}

variable "log_retention_days" {
  description = "Retention of Log Analytics and Application Insights, in days."
  type        = number
  default     = 30
}

variable "log_daily_quota_gb" {
  description = "Daily ingestion cap, in GB, for the workspace and for Application Insights. It can be raised temporarily during an incident."
  type        = number
  default     = 1
}

variable "alert_email_receivers" {
  description = "Email recipients of the alerts. Empty list: alerts exist but send no notifications."
  type        = list(string)
  default     = []
}
