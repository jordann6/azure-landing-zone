terraform {
  required_version = ">= 1.6.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.12"
    }
  }

  # This root creates the storage account it stores its own state in. The first
  # apply runs against the previous backend through -backend-config overrides,
  # then scripts/migrate-state-backend.sh moves this state (and every other
  # root's) into the account below. See docs/adr/0001-dedicated-state-backend.md.
  backend "azurerm" {
    resource_group_name  = "rg-alz-tfstate"
    storage_account_name = "stalztfstatejn"
    container_name       = "tfstate"
    key                  = "azure-landing-zone/bootstrap.terraform.tfstate"
    use_azuread_auth     = true
  }
}

provider "azurerm" {
  # Shared keys are disabled on the state account, so container and blob calls
  # must use Entra ID.
  storage_use_azuread = true

  features {
    key_vault {
      purge_soft_delete_on_destroy = false
    }
  }
}
