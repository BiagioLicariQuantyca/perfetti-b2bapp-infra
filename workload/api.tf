# B2B API exposed to the mobile app: https://<apim>.azure-api.net/<api_path>/<api_version>/...
# forwarded to https://<function app>/api/...

# --- Function key, read by API Management from Key Vault ---
# Created only when function_key_secret_name is set: the secret must exist in Key Vault
# before API Management can reference it (second apply, see README).
resource "azurerm_api_management_named_value" "function_key" {
  count = var.function_key_secret_name == null ? 0 : 1

  name                = "func-api-key"
  display_name        = "func-api-key"
  api_management_name = module.apim.name
  resource_group_name = data.azurerm_resource_group.this.name
  secret              = true

  # Versionless secret identifier: a rotated key is picked up automatically within 4 hours.
  value_from_key_vault {
    secret_id = "${data.azurerm_key_vault.this.vault_uri}secrets/${var.function_key_secret_name}"
  }

  depends_on = [azurerm_key_vault_access_policy.apim]
}

# Backend pointing to the Function App. The function key is sent in the x-functions-key
# header: without it the Function App answers 401 (functions use AuthorizationLevel.Function).
resource "azurerm_api_management_backend" "func_api" {
  name                = "func-api"
  api_management_name = module.apim.name
  resource_group_name = data.azurerm_resource_group.this.name
  description         = "Function App ${module.func_api.name}"
  protocol            = "http"
  url                 = "https://${module.func_api.default_hostname}/api"

  dynamic "credentials" {
    for_each = azurerm_api_management_named_value.function_key
    content {
      header = {
        "x-functions-key" = "{{${credentials.value.name}}}"
      }
    }
  }
}

# --- API, versioned in the URL path ---
resource "azurerm_api_management_api_version_set" "this" {
  name                = var.api_path
  display_name        = "B2B App"
  api_management_name = module.apim.name
  resource_group_name = data.azurerm_resource_group.this.name
  versioning_scheme   = "Segment"
}

resource "azurerm_api_management_api" "this" {
  name                = "${var.api_path}-${var.api_version}"
  display_name        = "B2B App"
  api_management_name = module.apim.name
  resource_group_name = data.azurerm_resource_group.this.name

  path           = var.api_path
  version        = var.api_version
  version_set_id = azurerm_api_management_api_version_set.this.id
  revision       = "1"
  protocols      = ["https"]
  api_type       = "http"

  # Callers authenticate with a bearer token, not with API Management subscription keys.
  subscription_required = false
}

# Wildcard operations: every request is forwarded to the Function App, so developers can add
# endpoints without changing API Management. To be replaced by an OpenAPI import once the API
# contract is stable (see README).
resource "azurerm_api_management_api_operation" "wildcard" {
  for_each = toset(["GET", "POST", "PUT", "PATCH", "DELETE"])

  operation_id        = "${lower(each.key)}-all"
  display_name        = "${each.key} /*"
  description         = "Forwards every ${each.key} request to the Function App."
  api_name            = azurerm_api_management_api.this.name
  api_management_name = module.apim.name
  resource_group_name = data.azurerm_resource_group.this.name
  method              = each.key
  url_template        = "/*"
}

# --- Policies ---
# Two scopes. The global policy (all APIs) validates the bearer token and limits concurrency
# and duration towards the backend, so every API, present or future, is protected by default.
# The API policy only routes to the backend and starts every section with <base /> to inherit
# the global one.
resource "azurerm_api_management_policy" "global" {
  api_management_id = module.apim.id

  xml_content = templatefile("${path.module}/policies/global.xml.tftpl", {
    jwt                     = var.jwt_validation
    max_concurrency         = var.api_max_concurrency
    backend_timeout_seconds = var.api_backend_timeout_seconds
  })
}

resource "azurerm_api_management_api_policy" "this" {
  api_name            = azurerm_api_management_api.this.name
  api_management_name = module.apim.name
  resource_group_name = data.azurerm_resource_group.this.name

  xml_content = templatefile("${path.module}/policies/api.xml.tftpl", {
    backend_id = azurerm_api_management_backend.func_api.name
  })

  # The global policy must be in place before the API can be reached.
  depends_on = [azurerm_api_management_policy.global]
}
