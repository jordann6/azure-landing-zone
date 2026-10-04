terraform {
  required_version = ">= 1.6.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.100"
    }
    # azapi covers three things azurerm 3.x cannot express: a Container Apps
    # environment with public network access disabled, a Front Door origin that
    # targets a Container Apps environment over Private Link, and the Entra
    # External ID tenant.
    azapi = {
      source  = "azure/azapi"
      version = "~> 2.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }

  # Its own state, like workload/. The member portal is an hourly-billed layer
  # deployed for a demo and destroyed on its own.
  backend "azurerm" {
    resource_group_name  = "rg-tfbackend-jordprojs"
    storage_account_name = "sttfbejordprojs8557"
    container_name       = "tfstate"
    key                  = "azure-landing-zone/portal.terraform.tfstate"
  }
}

provider "azurerm" {
  features {
    resource_group {
      prevent_deletion_if_contains_resources = false
    }
  }
}

provider "azapi" {}

# The base landing zone: central Log Analytics workspace and the ops action
# group. The portal lands under the same policies and logs to the same place.
data "terraform_remote_state" "base" {
  backend = "azurerm"
  config = {
    resource_group_name  = "rg-tfbackend-jordprojs"
    storage_account_name = "sttfbejordprojs8557"
    container_name       = "tfstate"
    key                  = "azure-landing-zone/dev.terraform.tfstate"
  }
}

data "azurerm_client_config" "current" {}
