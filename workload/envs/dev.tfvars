subscription_id     = "2fca6156-efd9-4da0-8ec1-ee5e8c7223e8"
resource_group_name = "weu-ita-lms-rg-p"
environment         = "dev"

key_vault_name = "weu-ita-lms-kv"

# --- API Management ---
apim_sku_name        = "Consumption_0"
apim_publisher_name  = "Perfetti Van Melle"
apim_publisher_email = "biagio.licari@quantyca.it" # temporary: replace with a shared mailbox

# --- Function App ---
# Flex Consumption: scales to zero, no cost while idle.
function_hosting = "flex"

# For Python: { name = "python", version = "3.13" }. Change only before the first deployment.
function_runtime = {
  name    = "dotnet-isolated"
  version = "10.0"
}
function_instance_memory_in_mb       = 2048
function_maximum_instance_count      = 40
function_always_ready_http_instances = 0

# Non-secret values and Key Vault references only. The Key Vault is shared with the other
# environments: suffix the secret names with the environment, for example:
#   SALESFORCE_BASE_URL      = "https://<sandbox>.sandbox.my.salesforce.com"
#   SALESFORCE_CLIENT_SECRET = "@Microsoft.KeyVault(SecretUri=https://weu-ita-lms-kv.vault.azure.net/secrets/salesforce-client-secret-dev)"
function_app_settings = {}

# Key Vault secret holding the "apim" host key of the Function App.
function_key_secret_name = "apim-function-key-dev"

# --- API ---
api_max_concurrency         = 20
api_backend_timeout_seconds = 25

# Bearer token validation. null = every request is rejected with 401.
# Test tokens until Entra External ID is available: public key of the Key Vault secret
# jwt-test-signing-key, printed by tools/test-jwt/create-signing-key.sh.
jwt_validation = {
  issuers   = ["urn:b2bapp:test-issuer"]
  audiences = ["api://b2bapp-test"]
  signing_keys = [{
    id = "test-1"
    n  = "3WE14_Rd-K-Q9HaexiBfKFIR1Cw4UTGBPDwmSaigsz1XBhyYGrjRPhlongzYn-c6wCfBHUsTqsVqp3Dc6KrcNwq0fq1qbMh9kHh_kx9ZsFt3qYwGhNonGvPBgLz4dH4bd0a4de4hB97e0zb-4uwEIcjiEXUGEEh8E64fJVFROpW06QIm4AWWdJdN4iVc0_knH9JZk_4EdlD9l1T3LdjVP4gZECT5k_M2h5lV5g5ZdUUX2hhiObDGNEdNSNqR36xisBIX1lrFIp-RXXcYmfTBQ7Z2sLAfvNbfp8iqPz3-dS0g4Z0ieIyV3hXF2G6ypkvHw_Zr2eKJVHeKSWd3JK2XRQ"
  }]
}

# --- Alerts ---
alert_api_server_errors_threshold = 5
# Action group to notify, for example the one of the platform root once it has recipients.
alert_action_group_name = null
