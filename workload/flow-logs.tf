# ── Prod VNet flow log (follows the base) ────────────────────────────────────
# No variable of its own: when the base root is deployed with enable_flow_logs it
# publishes the storage account, and the prod VNet joins the same log set and the
# same traffic-analytics workspace. Base off means this file creates nothing.

locals {
  flow_storage_id = try(data.terraform_remote_state.base.outputs.flow_log_storage_account_id, null)
  flow_law_guid   = try(data.terraform_remote_state.base.outputs.log_analytics_workspace_guid, null)
  flow_enabled    = local.flow_storage_id != null && local.flow_law_guid != null
}

data "azurerm_network_watcher" "this" {
  count = local.flow_enabled ? 1 : 0

  name                = "NetworkWatcher_${var.location}"
  resource_group_name = "NetworkWatcherRG"
}

resource "azurerm_network_watcher_flow_log" "prod" {
  count = local.flow_enabled ? 1 : 0

  name                 = "fl-${var.project}-prod"
  network_watcher_name = data.azurerm_network_watcher.this[0].name
  resource_group_name  = data.azurerm_network_watcher.this[0].resource_group_name
  target_resource_id   = azurerm_virtual_network.prod.id
  storage_account_id   = local.flow_storage_id
  enabled              = true
  version              = 2
  tags                 = local.tags

  # checkov:skip=CKV_AZURE_12:7 days of raw logs keeps demo storage near zero; the
  # base root owns the real retention knob (flow_log_retention_days).
  retention_policy {
    enabled = true
    days    = 7
  }

  traffic_analytics {
    enabled               = true
    interval_in_minutes   = 10
    workspace_id          = local.flow_law_guid
    workspace_region      = var.location
    workspace_resource_id = local.law_id
  }
}
