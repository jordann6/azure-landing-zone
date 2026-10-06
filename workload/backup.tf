# Azure Backup with soft delete and geo-redundant storage, protecting the Postgres
# server. Soft delete makes a deleted backup recoverable within the retention window
# (tamper-resistance), and geo-redundancy gives the cross-region copy. Mirrors
# aws-landing-zone/workload/backup.tf (Vault Lock WORM plus a cross-region DR copy).
#
# Vault immutability (the Locked-WORM equivalent of AWS Vault Lock) is the
# production upgrade: it is exposed by azurerm v4 (this repo is pinned to azurerm
# 3.117 for parity with the base landing zone) and can be locked in the portal. The
# backup_immutability_locked variable is reserved for that upgrade.

resource "azurerm_data_protection_backup_vault" "prod" {
  name                = "bv-${var.project}-prod"
  resource_group_name = azurerm_resource_group.prod.name
  location            = azurerm_resource_group.prod.location
  datastore_type      = "VaultStore"
  redundancy          = "GeoRedundant" # the cross-region copy

  soft_delete                = "On"
  retention_duration_in_days = 14

  identity {
    type = "SystemAssigned"
  }

  tags = local.tags
}

resource "azurerm_data_protection_backup_policy_postgresql_flexible_server" "prod" {
  name     = "bkpol-${var.project}-postgres"
  vault_id = azurerm_data_protection_backup_vault.prod.id

  backup_repeating_time_intervals = ["R/2026-01-01T05:00:00+00:00/P1D"]
  time_zone                       = "UTC"

  default_retention_rule {
    life_cycle {
      duration        = "P${var.backup_retention_days}D"
      data_store_type = "VaultStore"
    }
  }
}

# The vault identity needs the long-term-retention backup role to back up the
# server. Assigned at the resource-group scope (not the server) because the role
# includes Microsoft.Resources/subscriptions/resourceGroups/read, which only takes
# effect at RG scope or above; a server-scoped assignment leaves the vault unable
# to read the RG and the backup configuration fails with AuthorizationFailed.
resource "azurerm_role_assignment" "backup_pg" {
  scope                = azurerm_resource_group.prod.id
  role_definition_name = "PostgreSQL Flexible Server Long Term Retention Backup Role"
  principal_id         = azurerm_data_protection_backup_vault.prod.identity[0].principal_id
}

resource "azurerm_data_protection_backup_instance_postgresql_flexible_server" "prod" {
  name             = "bi-${var.project}-postgres"
  location         = azurerm_resource_group.prod.location
  vault_id         = azurerm_data_protection_backup_vault.prod.id
  server_id        = azurerm_postgresql_flexible_server.prod.id
  backup_policy_id = azurerm_data_protection_backup_policy_postgresql_flexible_server.prod.id

  depends_on = [azurerm_role_assignment.backup_pg]
}
