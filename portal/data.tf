# ── Data tier: Azure SQL with a failover group ──────────────────────────────
# Two logical servers (one per region) in the phi resource group, both with
# public network access disabled (the base phi policy would deny otherwise)
# and Entra-only authentication. The database lives on the primary; the
# failover group creates and maintains the geo-secondary and publishes one
# read-write listener, <fog>.database.windows.net, that always points at
# whichever server is primary. Both regions' apps use that listener.

resource "azurerm_mssql_server" "region" {
  # checkov:skip=CKV2_AZURE_45:Microsoft Defender for SQL is a paid per-server plan, off by default like the other Defender plans in the base landing zone.
  # checkov:skip=CKV2_AZURE_2:Vulnerability assessment requires Microsoft Defender for SQL (paid, off by default) and a storage account for scan results.
  # checkov:skip=CKV_AZURE_24:Audit events go to the central Log Analytics workspace, whose retention is set once in the base landing zone (30 days for the demo; docs/hipaa-mapping.md records the gap). The 90-day check applies to a storage-account audit target, which is not used.
  for_each = local.regions

  name                          = "sql-${var.project}-portal-${each.value.short}-${local.suffix}"
  resource_group_name           = azurerm_resource_group.data.name
  location                      = each.value.location
  version                       = "12.0"
  minimum_tls_version           = "1.2"
  public_network_access_enabled = false
  tags                          = azurerm_resource_group.data.tags

  # Entra-only. The app's managed identity is the administrator, so no SQL
  # login or password exists. Trade-off: the app holds admin on its own
  # database; production would grant it a contained user with db_datareader
  # and db_datawriter, created by a deployment job inside the VNet.
  azuread_administrator {
    login_username              = azurerm_user_assigned_identity.app.name
    object_id                   = azurerm_user_assigned_identity.app.principal_id
    tenant_id                   = data.azurerm_client_config.current.tenant_id
    azuread_authentication_only = true
  }
}

# Auditing to the central workspace: every login and query against member
# data is recorded (HIPAA 164.312(b) audit controls).
resource "azurerm_mssql_server_extended_auditing_policy" "region" {
  for_each = local.regions

  server_id              = azurerm_mssql_server.region[each.key].id
  log_monitoring_enabled = true
}

resource "azurerm_monitor_diagnostic_setting" "sql_audit" {
  for_each = local.regions

  name                       = "diag-sql-audit"
  target_resource_id         = "${azurerm_mssql_server.region[each.key].id}/databases/master"
  log_analytics_workspace_id = local.law_id

  enabled_log { category = "SQLSecurityAuditEvents" }

  depends_on = [azurerm_mssql_server_extended_auditing_policy.region]
}

resource "azurerm_mssql_database" "portal" {
  # checkov:skip=CKV_AZURE_224:Ledger is irreversible once enabled and not needed for this demo database.
  # checkov:skip=CKV_AZURE_229:Zone redundancy is not available on General Purpose serverless; regional resilience comes from the failover group.
  name      = "portal"
  server_id = azurerm_mssql_server.region["primary"].id
  sku_name  = var.sql_sku

  # Serverless, but never paused: auto-pause is not supported on a database in
  # a failover group, so -1 disables it.
  min_capacity                = 0.5
  auto_pause_delay_in_minutes = -1
  max_size_gb                 = 5
  storage_account_type        = "Local"
  tags                        = azurerm_resource_group.data.tags
}

resource "azurerm_mssql_failover_group" "portal" {
  name      = "fog-${var.project}-portal-${local.suffix}"
  server_id = azurerm_mssql_server.region["primary"].id
  databases = [azurerm_mssql_database.portal.id]
  tags      = azurerm_resource_group.data.tags

  partner_server {
    id = azurerm_mssql_server.region["secondary"].id
  }

  # Automatic failover after a 60-minute grace period (the minimum) for a real
  # outage. The drill uses a planned, manual failover to measure RTO and RPO.
  read_write_endpoint_failover_policy {
    mode          = "Automatic"
    grace_minutes = 60
  }
}

# ── Private connectivity to SQL ─────────────────────────────────────────────
resource "azurerm_private_dns_zone" "sql" {
  name                = "privatelink.database.windows.net"
  resource_group_name = azurerm_resource_group.data.name
  tags                = azurerm_resource_group.data.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "sql" {
  for_each = local.regions

  name                  = "sql-to-${each.value.short}"
  resource_group_name   = azurerm_resource_group.data.name
  private_dns_zone_name = azurerm_private_dns_zone.sql.name
  virtual_network_id    = azurerm_virtual_network.region[each.key].id
  registration_enabled  = false
  tags                  = azurerm_resource_group.data.tags
}

# Each server gets a private endpoint in its own region's VNet. With the zone
# linked to both VNets and the VNets peered, the failover group listener
# resolves to the current primary's private IP from either region.
resource "azurerm_private_endpoint" "sql" {
  for_each = local.regions

  name                = "pe-${var.project}-sql-${each.value.short}"
  location            = each.value.location
  resource_group_name = azurerm_resource_group.data.name
  subnet_id           = azurerm_subnet.pe[each.key].id
  tags                = azurerm_resource_group.data.tags

  private_service_connection {
    name                           = "sql-${each.value.short}"
    private_connection_resource_id = azurerm_mssql_server.region[each.key].id
    subresource_names              = ["sqlServer"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "sql"
    private_dns_zone_ids = [azurerm_private_dns_zone.sql.id]
  }
}
