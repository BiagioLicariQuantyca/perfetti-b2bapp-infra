# The resource group already exists and is not managed by Terraform: only its location and
# tags are read.
data "azurerm_resource_group" "this" {
  name = var.resource_group_name
}
