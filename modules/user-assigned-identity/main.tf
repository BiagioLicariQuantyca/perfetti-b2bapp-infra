# User-assigned managed identity. Access is granted on the target resources (role
# assignments or access policies), not in this module.
# Federated credentials are deliberately excluded: letting a system outside Azure use the
# identity must be an explicit decision, made outside the module.
resource "azurerm_user_assigned_identity" "this" {
  name                = var.name
  resource_group_name = var.resource_group_name
  location            = var.location
  tags                = var.tags
}

resource "azurerm_management_lock" "this" {
  count = var.lock == null ? 0 : 1

  name       = "lock-${var.name}"
  scope      = azurerm_user_assigned_identity.this.id
  lock_level = var.lock.level
  notes      = var.lock.notes
}
