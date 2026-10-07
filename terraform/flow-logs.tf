# ── VNet flow logs (gated) ───────────────────────────────────────────────────
# Accepted and denied connections for the hub VNet, in the same workspace as
# every other signal. NSG flow logs can no longer be created (Microsoft retired
# them), so this targets the VNet itself, which also covers the firewall and
# Bastion subnets that carry no NSG. Needs azurerm 4.x (docs/adr/0003-azurerm-v4.md).
#
# One storage account holds the raw logs for the hub and, through the
# flow_log_storage_account_id output, the prod VNet in workload/. Traffic
# analytics writes the queryable NTANetAnalytics table to the workspace.
#
# Network Watcher is created by Azure the first time a VNet appears in a region
# and lives in NetworkWatcherRG, outside this state, so it is read, not managed.

resource "random_string" "flow" {
  count = var.enable_flow_logs ? 1 : 0

  length  = 6
  upper   = false
  special = false
}

data "azurerm_network_watcher" "this" {
  count = var.enable_flow_logs ? 1 : 0

  name                = "NetworkWatcher_${var.location}"
  resource_group_name = "NetworkWatcherRG"
}

resource "azurerm_user_assigned_identity" "flow" {
  count = var.enable_flow_logs ? 1 : 0

  name                = "id-${var.project}-flowlogs"
  location            = azurerm_resource_group.logging.location
  resource_group_name = azurerm_resource_group.logging.name
  tags                = local.tags
}

# The storage account reads the CMK as this identity, so the identity needs the
# vault role before the account is created.
resource "azurerm_role_assignment" "flow_kms" {
  count = var.enable_flow_logs ? 1 : 0

  scope                = azurerm_key_vault.cmk.id
  role_definition_name = "Key Vault Crypto Service Encryption User"
  principal_id         = azurerm_user_assigned_identity.flow[0].principal_id
}

resource "azurerm_storage_account" "flow" {
  count = var.enable_flow_logs ? 1 : 0

  name                     = "st${replace(var.project, "-", "")}flow${random_string.flow[0].result}"
  resource_group_name      = azurerm_resource_group.logging.name
  location                 = azurerm_resource_group.logging.location
  account_kind             = "StorageV2"
  account_tier             = "Standard"
  account_replication_type = "LRS"

  min_tls_version                   = "TLS1_2"
  https_traffic_only_enabled        = true
  allow_nested_items_to_be_public   = false
  shared_access_key_enabled         = true
  cross_tenant_replication_enabled  = false
  infrastructure_encryption_enabled = true
  public_network_access_enabled     = true

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.flow[0].id]
  }

  customer_managed_key {
    key_vault_key_id          = azurerm_key_vault_key.cmk.versionless_id
    user_assigned_identity_id = azurerm_user_assigned_identity.flow[0].id
  }

  blob_properties {
    delete_retention_policy {
      days = 7
    }
  }

  sas_policy {
    expiration_period = "01.00:00:00"
  }

  # Default-Deny with the trusted-services bypass: Network Watcher writes the
  # logs as a trusted Microsoft service, so no IP or VNet rule is needed.
  network_rules {
    default_action = "Deny"
    bypass         = ["AzureServices", "Logging", "Metrics"]
  }

  tags = local.tags

  # checkov:skip=CKV_AZURE_33:Queue service is not used; flow logs write blobs only.
  # checkov:skip=CKV_AZURE_59:Public network access stays on only so the Deny
  # network rule (above) is the control; Network Watcher is a trusted service and
  # no other path is allowed.
  # checkov:skip=CKV2_AZURE_1:Customer-managed key is set (customer_managed_key).
  # checkov:skip=CKV_AZURE_206:LRS on purpose. Flow logs are rebuilt traffic
  # telemetry kept for days, not records that need a geo-redundant copy.
  # checkov:skip=CKV2_AZURE_33:Private endpoint for a short-retention log account
  # costs more than the data is worth in a demo; the Deny rule is the control.
  # checkov:skip=CKV2_AZURE_40:Shared key stays on because the azurerm provider
  # reads account properties over the data plane with it. Access is still gated by
  # the default-Deny network rule.
  # checkov:skip=CKV2_AZURE_21:Blob read/write/delete logging goes to the same
  # workspace through the account diagnostic setting only when audited; the
  # account holds telemetry, not business data.

  depends_on = [azurerm_role_assignment.flow_kms]
}

resource "azurerm_network_watcher_flow_log" "hub" {
  count = var.enable_flow_logs ? 1 : 0

  name                 = "fl-${var.project}-hub"
  network_watcher_name = data.azurerm_network_watcher.this[0].name
  resource_group_name  = data.azurerm_network_watcher.this[0].resource_group_name
  target_resource_id   = azurerm_virtual_network.hub.id
  storage_account_id   = azurerm_storage_account.flow[0].id
  enabled              = true
  version              = 2
  tags                 = local.tags

  # checkov:skip=CKV_AZURE_12:Raw logs keep flow_log_retention_days (default 7) to
  # hold demo storage near zero. Raise the variable to 90 or more for a real tier;
  # traffic analytics rows follow the workspace retention regardless.
  retention_policy {
    enabled = true
    days    = var.flow_log_retention_days
  }

  traffic_analytics {
    enabled               = true
    interval_in_minutes   = 10
    workspace_id          = azurerm_log_analytics_workspace.central.workspace_id
    workspace_region      = azurerm_log_analytics_workspace.central.location
    workspace_resource_id = azurerm_log_analytics_workspace.central.id
  }
}
