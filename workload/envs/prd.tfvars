subscription_id     = "2fca6156-efd9-4da0-8ec1-ee5e8c7223e8"
resource_group_name = "weu-ita-lms-rg-p"
environment         = "prd"

key_vault_name = "weu-ita-lms-kv"

# --- API Management ---
apim_sku_name        = "Consumption_0"
apim_publisher_name  = "Perfetti Van Melle"
apim_publisher_email = "biagio.licari@quantyca.it" # temporary: replace with a shared mailbox

# --- Function App ---
# Elastic Premium: always ready instances, no cold starts, billed for at least one instance.
# The switch from flex creates func-api-b2bapp-prd-weu-002 and deletes the Flex Consumption app:
# see "Change the hosting plan" in the README.
function_hosting = "premium"

# For Python: { name = "python", version = "3.13" }. Change only before the first deployment.
function_runtime = {
  name    = "dotnet-isolated"
  version = "10.0"
}

function_premium = {
  sku_name               = "EP1"
  always_ready_instances = 1
  maximum_instance_count = 20
}

# Non-secret values and Key Vault references only. The Key Vault is shared with the other
# environments: suffix the secret names with the environment, for example:
#   SALESFORCE_BASE_URL      = "https://<instance>.my.salesforce.com"
#   SALESFORCE_CLIENT_SECRET = "@Microsoft.KeyVault(SecretUri=https://weu-ita-lms-kv.vault.azure.net/secrets/salesforce-client-secret-prd)"
function_app_settings = {}

# Key Vault secret holding the "apim" host key of the Function App.
function_key_secret_name = "apim-function-key"

# --- API ---
api_max_concurrency         = 20
api_backend_timeout_seconds = 25

# Bearer token validation. null = every request is rejected with 401.
# Production accepts only Entra External ID tokens: until they are available it stays closed, and
# test tokens are accepted only in dev.
jwt_validation = null

# --- Alerts ---
alert_api_server_errors_threshold = 5
# Action group to notify, for example the one of the platform root once it has recipients.
alert_action_group_name = null
