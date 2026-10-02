# ── Central logging + Defender for Cloud ─────────────────────────────────────
# One Log Analytics workspace in a dedicated logging RG, with diagnostic settings
# shipping platform telemetry to it. Microsoft Defender for Cloud's free
# foundational CSPM is on by the subscription default and renders the CIS
# regulatory-compliance assessment against the initiative assigned in policies.tf.
# Paid Defender plans are gated behind enable_defender_standard (they bill per
# resource) so a default apply stays free.

resource "azurerm_resource_group" "logging" {
  name     = "rg-${var.project}-logging"
  location = var.location
  tags     = merge(local.tags, { environment = "platform" })
}

resource "azurerm_log_analytics_workspace" "central" {
  name                = "log-${var.project}-central"
  location            = azurerm_resource_group.logging.location
  resource_group_name = azurerm_resource_group.logging.name
  sku                 = "PerGB2018"
  retention_in_days   = 30
  tags                = local.tags
}

# Ship hub VNet telemetry to the workspace. Metrics only: a VNet emits few log
# categories, and AllMetrics is always valid, so the setting applies cleanly.
resource "azurerm_monitor_diagnostic_setting" "hub_vnet" {
  name                       = "diag-hub-vnet"
  target_resource_id         = azurerm_virtual_network.hub.id
  log_analytics_workspace_id = azurerm_log_analytics_workspace.central.id

  metric {
    category = "AllMetrics"
    enabled  = true
  }
}

# Ship Key Vault audit logs (the CIS-relevant ones) to the workspace.
resource "azurerm_monitor_diagnostic_setting" "keyvault" {
  name                       = "diag-keyvault"
  target_resource_id         = azurerm_key_vault.cmk.id
  log_analytics_workspace_id = azurerm_log_analytics_workspace.central.id

  enabled_log {
    category = "AuditEvent"
  }

  metric {
    category = "AllMetrics"
    enabled  = true
  }
}

# ── Defender for Cloud paid plans (gated) ────────────────────────────────────
locals {
  defender_plans = var.enable_defender_standard ? [
    "VirtualMachines",
    "KeyVaults",
    "StorageAccounts",
    "Arm",
  ] : []
}

resource "azurerm_security_center_subscription_pricing" "plans" {
  for_each      = toset(local.defender_plans)
  tier          = "Standard"
  resource_type = each.value
}
