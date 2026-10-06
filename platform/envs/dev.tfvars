subscription_id     = "2fca6156-efd9-4da0-8ec1-ee5e8c7223e8"
resource_group_name = "weu-ita-lms-rg-p"
environment         = "dev"

key_vault_name = "weu-ita-lms-kv"

log_retention_days = 30
log_daily_quota_gb = 1

# No recipients: the daily cap alert is visible in the portal but sends no notifications.
alert_email_receivers = []
