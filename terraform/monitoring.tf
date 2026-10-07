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
  # Only the Servers plan has sub-plans. Pinned so the bill is predictable (P1 is
  # about a third of P2); every other plan takes null.
  subplan = each.value == "VirtualMachines" ? var.defender_servers_subplan : null
}

# ── Azure Firewall logs (gated with the firewall) ────────────────────────────
# Every allow and deny decision the hub firewall makes, in resource-specific
# tables (AZFWNetworkRule, AZFWApplicationRule, ...) rather than the legacy
# AzureDiagnostics table, so queries are typed and cheaper to scan. Without
# this the firewall inspects egress but nobody can see what it decided.
resource "azurerm_monitor_diagnostic_setting" "firewall" {
  count = local.fw_azure_count

  name                           = "diag-firewall"
  target_resource_id             = azurerm_firewall.hub[0].id
  log_analytics_workspace_id     = azurerm_log_analytics_workspace.central.id
  log_analytics_destination_type = "Dedicated"

  enabled_log { category = "AZFWNetworkRule" }
  enabled_log { category = "AZFWApplicationRule" }
  enabled_log { category = "AZFWNatRule" }
  enabled_log { category = "AZFWThreatIntel" }

  metric {
    category = "AllMetrics"
    enabled  = true
  }
}

# ── Bastion session audit (gated with Bastion) ───────────────────────────────
# Bastion is the only admin path, so its audit log is the record of who
# connected to what, from where, and when.
resource "azurerm_monitor_diagnostic_setting" "bastion" {
  count = local.bastion_count

  name                       = "diag-bastion"
  target_resource_id         = azurerm_bastion_host.hub[0].id
  log_analytics_workspace_id = azurerm_log_analytics_workspace.central.id

  enabled_log { category = "BastionAuditLogs" }

  metric {
    category = "AllMetrics"
    enabled  = true
  }
}

# ── Subscription Activity Log ────────────────────────────────────────────────
# Control-plane history (who created, changed, or deleted what), policy
# evaluations including denies, and service health, in the same workspace as
# everything else so one query can join a change to its effect. Free to export.
resource "azurerm_monitor_diagnostic_setting" "activity_log" {
  name                       = "diag-activity-log"
  target_resource_id         = data.azurerm_subscription.current.id
  log_analytics_workspace_id = azurerm_log_analytics_workspace.central.id

  enabled_log { category = "Administrative" }
  enabled_log { category = "Security" }
  enabled_log { category = "Policy" }
  enabled_log { category = "Alert" }
  enabled_log { category = "ServiceHealth" }
  enabled_log { category = "ResourceHealth" }
  enabled_log { category = "Recommendation" }
  enabled_log { category = "Autoscale" }
}
