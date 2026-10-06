terraform {
  required_version = ">= 1.6.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
    # Entra ID persona groups (identity.tf). Kept optional at apply time via the
    # create_entra_identity flag, but the provider is always declared so the
    # config parses and validates.
    azuread = {
      source  = "hashicorp/azuread"
      version = "~> 2.50"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }

  backend "azurerm" {
    resource_group_name  = "rg-alz-tfstate"
    storage_account_name = "stalztfstatejn"
    container_name       = "tfstate"
    key                  = "azure-landing-zone/dev.terraform.tfstate"
    use_azuread_auth     = true
  }
}

provider "azurerm" {
  features {
    resource_group {
      prevent_deletion_if_contains_resources = false
    }
    key_vault {
      # Let terraform destroy actually remove the vault; purge is still blocked
      # by purge protection for the soft-delete window (the standing residual).
      purge_soft_delete_on_destroy = false
    }
  }
}

provider "azuread" {}
