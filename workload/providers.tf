terraform {
  required_version = ">= 1.6.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.100"
    }
    azuread = {
      source  = "hashicorp/azuread"
      version = "~> 2.50"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }

  # Its own state. This is the paved-road prod workload (data tier + AKS): the
  # hourly-billed layer, deployed for a demo and destroyed on its own. Mirrors the
  # separate workload root in aws-landing-zone/workload.
  backend "azurerm" {
    resource_group_name  = "rg-tfbackend-jordprojs"
    storage_account_name = "sttfbejordprojs8557"
    container_name       = "tfstate"
    key                  = "azure-landing-zone/workload.terraform.tfstate"
  }
}

provider "azurerm" {
  features {
    resource_group {
      prevent_deletion_if_contains_resources = false
    }
    key_vault {
      purge_soft_delete_on_destroy = false
    }
  }
}

provider "azuread" {}

# The governance/network landing zone (terraform/ root): the hub VNet, the Azure
# Firewall private IP the prod tier routes egress through, and the central Log
# Analytics workspace. The prod tier lands against these, the way the AWS workload
# root consumes the governance and network account outputs.
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

locals {
  hub_vnet_id         = data.terraform_remote_state.base.outputs.hub_vnet_id
  firewall_private_ip = data.terraform_remote_state.base.outputs.firewall_private_ip
  fw_policy_id        = data.terraform_remote_state.base.outputs.firewall_policy_id
  law_id              = data.terraform_remote_state.base.outputs.log_analytics_workspace_id

  # hub_vnet_id: /subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.Network/virtualNetworks/<name>
  hub_vnet_name = element(split("/", local.hub_vnet_id), length(split("/", local.hub_vnet_id)) - 1)
  hub_rg_name   = element(split("/", local.hub_vnet_id), 4)

  tags = {
    project             = "azure-landing-zone"
    environment         = "prod"
    owner               = var.owner
    managed_by          = "terraform"
    cost_center         = var.cost_center
    data_classification = "confidential"
  }
}
