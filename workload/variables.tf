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

# --- API Management ---

variable "apim_sku_name" {
  description = "API Management tier and units. Consumption_0 cannot be changed to another tier on the same instance."
  type        = string
  default     = "Consumption_0"
}

variable "apim_publisher_name" {
  description = "Name of the organization publishing the APIs."
  type        = string
}

variable "apim_publisher_email" {
  description = "Email receiving API Management service notifications. Prefer a shared mailbox; it can be changed in place."
  type        = string
}

variable "apim_telemetry_sampling_percentage" {
  description = "Percentage of API requests sent to Application Insights."
  type        = number
  default     = 100
}

# --- Function App ---

variable "function_runtime" {
  description = "Language stack of the API Function App. One language per app; change it only before the first code deployment."
  type = object({
    name    = string
    version = string
  })
  default = {
    name    = "dotnet-isolated"
    version = "10.0"
  }
}

variable "function_instance_memory_in_mb" {
  description = "Instance memory of the API Function App: 512, 2048 or 4096 MB."
  type        = number
  default     = 2048
}

variable "function_maximum_instance_count" {
  description = "Maximum on-demand instances of the API Function App."
  type        = number
  default     = 40
}

variable "function_always_ready_http_instances" {
  description = "Always ready instances for HTTP triggers. 0 = scale to zero, with cold starts and no idle cost."
  type        = number
  default     = 0
}

variable "function_app_settings" {
  description = "Application settings of the API Function App: non-secret values and Key Vault references only."
  type        = map(string)
  default     = {}

  validation {
    condition = alltrue([
      for key in keys(var.function_app_settings) : !contains([
        "AzureWebJobsStorage", "DEPLOYMENT_STORAGE_CONNECTION_STRING",
        "APPLICATIONINSIGHTS_CONNECTION_STRING", "FUNCTIONS_WORKER_RUNTIME", "FUNCTIONS_EXTENSION_VERSION",
      ], key)
    ])
    error_message = "Platform settings (storage, Application Insights, runtime) are managed by Terraform and cannot be overridden in function_app_settings."
  }
}

variable "function_key_secret_name" {
  description = "Name of the Key Vault secret holding the Function App host key used by API Management. null until the key has been created and stored (second apply)."
  type        = string
  default     = null
}

# --- API ---

variable "api_path" {
  description = "Base path of the API in API Management."
  type        = string
  default     = "b2bapp"
}

variable "api_version" {
  description = "API version, exposed as a path segment (/<api_path>/<api_version>/...)."
  type        = string
  default     = "v1"
}

variable "api_backend_timeout_seconds" {
  description = "Seconds API Management waits for the Function App response. Keep it below the 30-second request limit of the Consumption tier."
  type        = number
  default     = 25

  validation {
    condition     = var.api_backend_timeout_seconds >= 1 && var.api_backend_timeout_seconds <= 29
    error_message = "api_backend_timeout_seconds must be between 1 and 29."
  }
}

variable "api_max_concurrency" {
  description = "Maximum concurrent requests forwarded to the backend of each API (limit-concurrency policy). Excess requests receive 429."
  type        = number
  default     = 20
}

variable "jwt_validation" {
  description = <<-EOT
    Bearer token validation, applied in the global policy to every API. null = every request is
    rejected with 401 (closed by default).
    Test tokens: signing_keys with the public key of the test key pair.
    Entra External ID: openid_config_url of the external tenant and the API audience.
    required_claims: claims the token must contain, for example the scp scope with separator " ".
  EOT
  type = object({
    issuers           = optional(list(string), [])
    audiences         = list(string)
    openid_config_url = optional(string)
    signing_keys = optional(list(object({
      id = string
      n  = string
      e  = optional(string, "AQAB")
    })), [])
    required_claims = optional(list(object({
      name      = string
      values    = list(string)
      match     = optional(string, "all")
      separator = optional(string)
    })), [])
  })
  default = null

  validation {
    condition     = var.jwt_validation == null || try(length(var.jwt_validation.audiences) > 0, false)
    error_message = "jwt_validation.audiences must contain at least one audience."
  }

  validation {
    condition     = var.jwt_validation == null || try(var.jwt_validation.openid_config_url != null || length(var.jwt_validation.signing_keys) > 0, false)
    error_message = "jwt_validation needs openid_config_url or at least one signing key."
  }
}

# --- Alerts ---

variable "alert_api_server_errors_threshold" {
  description = "Number of API Management responses with a 5xx status in 15 minutes above which the alert fires."
  type        = number
  default     = 5
}

variable "alert_action_group_name" {
  description = "Existing action group (for example the one of the platform root) notified by the alerts of this root. null = alerts visible in the portal only."
  type        = string
  default     = null
}
