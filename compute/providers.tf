terraform {
  required_version = ">= 1.6.0"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.100"
    }
  }
  backend "azurerm" {
    resource_group_name  = "rg-tfbackend-jordprojs"
    storage_account_name = "sttfbejordprojs8557"
    container_name       = "tfstate"
    key                  = "azure-landing-zone/compute.terraform.tfstate"
  }
}

provider "azurerm" {
  features {}
}

data "terraform_remote_state" "base" {
  backend = "azurerm"
  config = {
    resource_group_name  = "rg-tfbackend-jordprojs"
    storage_account_name = "sttfbejordprojs8557"
    container_name       = "tfstate"
    key                  = "azure-landing-zone/dev.terraform.tfstate"
  }
}

locals {
  # Empty compute state must still be destroyable after the base is removed.
  gallery = try(data.terraform_remote_state.base.outputs.compute_gallery, null)
  tags = {
    project             = "azure-landing-zone"
    environment         = "management"
    owner               = "jordann6"
    cost_center         = "platform"
    data_classification = "internal"
    managed_by          = "terraform"
  }
}
