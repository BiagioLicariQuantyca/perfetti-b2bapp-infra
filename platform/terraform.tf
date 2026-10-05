terraform {
  required_version = ">= 1.15.0, < 2.0.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 5.8"
    }
  }

  # Partial configuration: per-environment values are in envs/backend-<env>.hcl.
  # The state is reachable only with Entra ID authentication, without access keys.
  backend "azurerm" {
    key = "platform.tfstate"
  }
}
