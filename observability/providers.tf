terraform {
  required_version = ">= 1.6.0"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
  }
  backend "azurerm" {
    resource_group_name  = "rg-alz-tfstate"
    storage_account_name = "stalztfstatejn"
    container_name       = "tfstate"
    key                  = "azure-landing-zone/observability.terraform.tfstate"
    use_azuread_auth     = true
  }
}

provider "azurerm" {
  features {}
}

data "azurerm_subscription" "current" {}

# The base root owns the workspace and the ops action group; this root adds the
# alert coverage and security-findings routing on top, the way the AWS
# observability root reads the monitoring account's outputs.
data "terraform_remote_state" "base" {
  backend = "azurerm"
  config = {
    resource_group_name  = "rg-alz-tfstate"
    storage_account_name = "stalztfstatejn"
    container_name       = "tfstate"
    key                  = "azure-landing-zone/dev.terraform.tfstate"
    use_azuread_auth     = true
  }
}

locals {
  # The base must be deployed first. Absent outputs fail the preconditions in
  # alerts.tf with a readable message instead of an opaque null error, and a
  # destroy after the base teardown still parses.
  placeholder_id  = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/empty/providers/Microsoft.Insights/actionGroups/empty"
  action_group_id = coalesce(try(data.terraform_remote_state.base.outputs.ops_action_group_id, null), local.placeholder_id)
  law_id          = coalesce(try(data.terraform_remote_state.base.outputs.log_analytics_workspace_id, null), "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/empty/providers/Microsoft.OperationalInsights/workspaces/empty")
  logging_rg      = coalesce(try(data.terraform_remote_state.base.outputs.logging_resource_group_name, null), "rg-empty")
  base_ready      = try(data.terraform_remote_state.base.outputs.ops_action_group_id, null) != null

  tags = {
    project             = "azure-landing-zone"
    environment         = "platform"
    owner               = "jordann6"
    cost_center         = "platform"
    data_classification = "internal"
    managed_by          = "terraform"
  }
}
