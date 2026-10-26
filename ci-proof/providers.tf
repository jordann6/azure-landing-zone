terraform {
  required_version = ">= 1.6.0"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
  }
  # Key must match ci_state_key in bootstrap/ci-identities.tf: it is the only
  # state blob the CI identities may write.
  backend "azurerm" {
    resource_group_name  = "rg-alz-tfstate"
    storage_account_name = "stalztfstatejn"
    container_name       = "tfstate"
    key                  = "azure-landing-zone/ci-proof.terraform.tfstate"
    use_azuread_auth     = true
  }
}

provider "azurerm" {
  features {}

  # The apply identity holds Contributor on rg-alz-ci only, so it cannot
  # register resource providers at subscription scope. Registration is the
  # operator's job.
  resource_provider_registrations = "none"
}
