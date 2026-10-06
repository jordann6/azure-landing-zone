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
    key                  = "azure-landing-zone/secrets.terraform.tfstate"
    use_azuread_auth     = true
  }
}

provider "azurerm" {
  features {
    key_vault {
      purge_soft_delete_on_destroy = false
    }
  }
}

data "azurerm_client_config" "current" {}
data "azurerm_subscription" "current" {}

# The base owns the CMK vault, the workspace and the ops action group. The
# workload root owns the data-tier vault and may be absent (it is hourly).
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

data "terraform_remote_state" "workload" {
  backend = "azurerm"
  config = {
    resource_group_name  = "rg-alz-tfstate"
    storage_account_name = "stalztfstatejn"
    container_name       = "tfstate"
    key                  = "azure-landing-zone/workload.terraform.tfstate"
    use_azuread_auth     = true
  }
}

locals {
  placeholder_vault = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/empty/providers/Microsoft.KeyVault/vaults/empty"
  cmk_vault_id      = coalesce(try(data.terraform_remote_state.base.outputs.key_vault_id, null), local.placeholder_vault)
  law_id            = coalesce(try(data.terraform_remote_state.base.outputs.log_analytics_workspace_id, null), "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/empty/providers/Microsoft.OperationalInsights/workspaces/empty")
  logging_rg        = coalesce(try(data.terraform_remote_state.base.outputs.logging_resource_group_name, null), "rg-empty")
  action_group_id   = coalesce(try(data.terraform_remote_state.base.outputs.ops_action_group_id, null), "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/empty/providers/Microsoft.Insights/actionGroups/empty")
  base_ready        = try(data.terraform_remote_state.base.outputs.key_vault_id, null) != null

  # The data-tier vault exists only while the workload root is deployed. Its
  # absence is normal, so it is optional rather than a precondition.
  workload_vault_id = try(data.terraform_remote_state.workload.outputs.workload_key_vault_id, null)

  vaults = merge(
    { cmk = local.cmk_vault_id },
    local.workload_vault_id == null ? {} : { workload = local.workload_vault_id },
  )

  tags = {
    project             = "azure-landing-zone"
    environment         = "platform"
    owner               = "jordann6"
    cost_center         = "platform"
    data_classification = "internal"
    managed_by          = "terraform"
  }
}
