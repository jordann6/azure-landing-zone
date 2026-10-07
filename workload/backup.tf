# Azure Backup with soft delete and geo-redundant storage, protecting the Postgres
# server. Soft delete makes a deleted backup recoverable within the retention window
# (tamper-resistance), and geo-redundancy gives the cross-region copy. Mirrors
# aws-landing-zone/workload/backup.tf (Vault Lock WORM plus a cross-region DR copy).
#
# Vault immutability (the Locked-WORM equivalent of AWS Vault Lock) is the
# production upgrade: azurerm v4 exposes it (this repo is on azurerm ~> 4.0, see
# ADR-0003). The backup_immutability_locked variable is reserved for that upgrade.

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

# The azurerm backup-instance resource calls an API version the service answers
# with 406 Not Acceptable for PostgreSQL flexible servers (azurerm 4.81.0, both
# create and delete). azapi pins the version the Azure CLI uses. The instance name
# follows the service's own pattern: server, server, a GUID.
resource "random_uuid" "backup_instance" {}

resource "azapi_resource" "backup_instance" {
  type      = "Microsoft.DataProtection/backupVaults/backupInstances@2025-07-01"
  name      = "${azurerm_postgresql_flexible_server.prod.name}-${azurerm_postgresql_flexible_server.prod.name}-${random_uuid.backup_instance.result}"
  parent_id = azurerm_data_protection_backup_vault.prod.id

  body = {
    properties = {
      objectType   = "BackupInstance"
      friendlyName = azurerm_postgresql_flexible_server.prod.name
      dataSourceInfo = {
        objectType       = "Datasource"
        datasourceType   = "Microsoft.DBforPostgreSQL/flexibleServers"
        resourceID       = azurerm_postgresql_flexible_server.prod.id
        resourceName     = azurerm_postgresql_flexible_server.prod.name
        resourceType     = "Microsoft.DBforPostgreSQL/flexibleServers"
        resourceUri      = azurerm_postgresql_flexible_server.prod.id
        resourceLocation = azurerm_resource_group.prod.location
      }
      policyInfo = {
        policyId = azurerm_data_protection_backup_policy_postgresql_flexible_server.prod.id
      }
    }
  }

  depends_on = [azurerm_role_assignment.backup_pg]
}
