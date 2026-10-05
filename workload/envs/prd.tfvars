subscription_id     = "2fca6156-efd9-4da0-8ec1-ee5e8c7223e8"
resource_group_name = "weu-ita-lms-rg-p"
environment         = "prd"

key_vault_name = "weu-ita-lms-kv"

# --- API Management ---
apim_sku_name        = "Consumption_0"
apim_publisher_name  = "Perfetti Van Melle"
apim_publisher_email = "biagio.licari@quantyca.it" # temporary: replace with a shared mailbox

# --- Function App ---
# For Python: { name = "python", version = "3.13" }. Change only before the first deployment.
function_runtime = {
  name    = "dotnet-isolated"
  version = "10.0"
}
function_instance_memory_in_mb       = 2048
function_maximum_instance_count      = 40
function_always_ready_http_instances = 0

# Non-secret values and Key Vault references only, for example:
#   SALESFORCE_BASE_URL      = "https://<instance>.my.salesforce.com"
#   SALESFORCE_CLIENT_SECRET = "@Microsoft.KeyVault(SecretUri=https://weu-ita-lms-kv.vault.azure.net/secrets/salesforce-client-secret)"
function_app_settings = {}

# Second apply: name of the Key Vault secret holding the "apim" host key of the Function App.
function_key_secret_name = null

# --- API ---
api_max_concurrency = 20

# Bearer token validation. null = every request is rejected with 401.
# Test tokens (until Entra External ID is available), after running tools/test-jwt/create-signing-key.sh:
#   jwt_validation = {
#     issuers      = ["urn:b2bapp:test-issuer"]
#     audiences    = ["api://b2bapp-test"]
#     signing_keys = [{ id = "test-1", n = "<modulus printed by the script>" }]
#   }
jwt_validation = null
