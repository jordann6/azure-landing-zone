# AKS Backup, operational tier, for the stateful demo namespace (slo-data).
#
# Operational tier only: crash-consistent incremental disk snapshots in a
# dedicated resource group, plus cluster-resource metadata in a blob container.
# Same-region restore, same or different cluster. The vault tier is not used,
# because it rejects disks with a disk encryption set (every PV here has one) and
# is not deployable through Terraform. No vaulted copy, no cross-region restore.
#
# The vault is demo-only and separate from bv-<project>-prod (the Postgres vault),
# with soft delete Off, so teardown leaves nothing behind. Operational snapshots
# are not covered by soft delete in any case. Role assignments follow
# learn.microsoft.com/azure/backup/azure-kubernetes-service-cluster-backup-concept.

resource "random_string" "aks_backup" {
  count   = local.backup_count
  length  = 6
  special = false
  upper   = false
}

resource "azurerm_resource_group" "aks_snapshots" {
  count    = local.backup_count
  name     = "rg-${var.project}-prod-aks-snapshots"
  location = azurerm_resource_group.prod.location
  tags     = local.tags
}

resource "azurerm_data_protection_backup_vault" "aks_demo" {
  count               = local.backup_count
  name                = "bv-${var.project}-aks-demo"
  resource_group_name = azurerm_resource_group.prod.name
  location            = azurerm_resource_group.prod.location
  datastore_type      = "OperationalStore"
  redundancy          = "LocallyRedundant"
  soft_delete         = "Off"
  immutability        = "Disabled"

  identity {
    type = "SystemAssigned"
  }

  tags = merge(local.tags, { purpose = "demo-only-restore-drill" })
}

# ── Backup extension storage (GPv2, same region, dedicated empty container) ──

resource "azurerm_user_assigned_identity" "aks_backup_storage" {
  count               = local.backup_count
  name                = "id-${var.project}-aks-backup-storage"
  location            = azurerm_resource_group.prod.location
  resource_group_name = azurerm_resource_group.prod.name
  tags                = local.tags
}

resource "azurerm_role_assignment" "aks_backup_storage_kms" {
  count                = local.backup_count
  scope                = azurerm_key_vault.workload.id
  role_definition_name = "Key Vault Crypto User"
  principal_id         = azurerm_user_assigned_identity.aks_backup_storage[0].principal_id
  principal_type       = "ServicePrincipal"
}

resource "azurerm_storage_account" "aks_backup" {
  count = local.backup_count

  name                     = "st${var.project}aksbkp${random_string.aks_backup[0].result}"
  resource_group_name      = azurerm_resource_group.prod.name
  location                 = azurerm_resource_group.prod.location
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
    identity_ids = [azurerm_user_assigned_identity.aks_backup_storage[0].id]
  }

  customer_managed_key {
    key_vault_key_id          = azurerm_key_vault_key.data.versionless_id
    user_assigned_identity_id = azurerm_user_assigned_identity.aks_backup_storage[0].id
  }

  sas_policy {
    expiration_period = "01.00:00:00"
  }

  # Default-Deny. The cluster reaches the account over the private endpoint
  # below; the backup vault is admitted as a resource instance and through the
  # trusted-services bypass, the two settings the AKS Backup docs require for a
  # network-restricted account.
  network_rules {
    default_action = "Deny"
    bypass         = ["AzureServices"]

    private_link_access {
      endpoint_resource_id = azurerm_data_protection_backup_vault.aks_demo[0].id
    }
  }

  tags = local.tags

  # checkov:skip=CKV_AZURE_33:Queue service is not used; the backup extension writes blobs only.
  # checkov:skip=CKV_AZURE_59:Public network access stays on only so the Deny network rule is the control, the same proven pattern as the flow-log account; the cluster uses the private endpoint.
  # checkov:skip=CKV2_AZURE_1:Customer-managed key is set (customer_managed_key).
  # checkov:skip=CKV_AZURE_206:LRS on purpose. Operational-tier metadata is same-region by design; there is no cross-region restore to feed.
  # checkov:skip=CKV2_AZURE_40:Shared key stays on because the azurerm provider reads account properties over the data plane with it; the extension and vault authenticate with Entra identities.
  # checkov:skip=CKV2_AZURE_38:Blob soft delete is off so the account and its container tear down with the session; the recovery points live in the snapshot resource group, not here.
  # checkov:skip=CKV2_AZURE_21:Blob logging is not wired for a session-lived metadata container.
  # checkov:skip=CKV2_AZURE_33:A private endpoint is configured (azurerm_private_endpoint.aks_backup_blob); the check does not follow the reference.

  depends_on = [azurerm_role_assignment.aks_backup_storage_kms]
}

resource "azurerm_storage_container" "aks_backup" {
  # checkov:skip=CKV2_AZURE_21:Blob logging is not wired for a session-lived metadata container.
  count                 = local.backup_count
  name                  = "aks-backup"
  storage_account_id    = azurerm_storage_account.aks_backup[0].id
  container_access_type = "private"
}

resource "azurerm_private_dns_zone" "blob" {
  count               = local.backup_count
  name                = "privatelink.blob.core.windows.net"
  resource_group_name = azurerm_resource_group.prod.name
  tags                = local.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "blob" {
  count                 = local.backup_count
  name                  = "blob-to-prod"
  resource_group_name   = azurerm_resource_group.prod.name
  private_dns_zone_name = azurerm_private_dns_zone.blob[0].name
  virtual_network_id    = azurerm_virtual_network.prod.id
  registration_enabled  = false
  tags                  = local.tags
}

resource "azurerm_private_endpoint" "aks_backup_blob" {
  count               = local.backup_count
  name                = "pe-${var.project}-aks-backup-blob"
  location            = azurerm_resource_group.prod.location
  resource_group_name = azurerm_resource_group.prod.name
  subnet_id           = azurerm_subnet.pe.id
  tags                = local.tags

  private_service_connection {
    name                           = "aks-backup-blob"
    private_connection_resource_id = azurerm_storage_account.aks_backup[0].id
    subresource_names              = ["blob"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "blob"
    private_dns_zone_ids = [azurerm_private_dns_zone.blob[0].id]
  }
}

# ── Extension and trusted access ─────────────────────────────────────────────

resource "azurerm_kubernetes_cluster_extension" "aks_backup" {
  count             = local.backup_count
  name              = "azure-aks-backup"
  cluster_id        = azurerm_kubernetes_cluster.prod.id
  extension_type    = "Microsoft.DataProtection.Kubernetes"
  release_train     = "stable"
  release_namespace = "dataprotection-microsoft"

  configuration_settings = {
    "configuration.backupStorageLocation.bucket"                = azurerm_storage_container.aks_backup[0].name
    "configuration.backupStorageLocation.config.resourceGroup"  = azurerm_resource_group.prod.name
    "configuration.backupStorageLocation.config.storageAccount" = azurerm_storage_account.aks_backup[0].name
    "configuration.backupStorageLocation.config.subscriptionId" = data.azurerm_client_config.current.subscription_id
    "credentials.tenantId"                                      = data.azurerm_client_config.current.tenant_id
  }

  depends_on = [
    azurerm_private_endpoint.aks_backup_blob,
    azurerm_private_dns_zone_virtual_network_link.blob,
    azurerm_firewall_policy_rule_collection_group.sre,
  ]
}

resource "azurerm_kubernetes_cluster_trusted_access_role_binding" "aks_backup" {
  count                 = local.backup_count
  name                  = "backup-vault"
  kubernetes_cluster_id = azurerm_kubernetes_cluster.prod.id
  roles                 = ["Microsoft.DataProtection/backupVaults/backup-operator"]
  source_resource_id    = azurerm_data_protection_backup_vault.aks_demo[0].id
}

# ── Role assignments from the prerequisites table ────────────────────────────

locals {
  aks_backup_vault_principal = try(azurerm_data_protection_backup_vault.aks_demo[0].identity[0].principal_id, null)

  aks_backup_roles = local.backup_count == 1 ? {
    extension_blob = {
      scope = azurerm_storage_account.aks_backup[0].id
      role  = "Storage Blob Data Contributor"
      who   = azurerm_kubernetes_cluster_extension.aks_backup[0].aks_assigned_identity[0].principal_id
    }
    vault_reader_cluster = {
      scope = azurerm_kubernetes_cluster.prod.id
      role  = "Reader"
      who   = local.aks_backup_vault_principal
    }
    vault_reader_snapshots = {
      scope = azurerm_resource_group.aks_snapshots[0].id
      role  = "Reader"
      who   = local.aks_backup_vault_principal
    }
    vault_disk_snapshot = {
      scope = azurerm_resource_group.aks_snapshots[0].id
      role  = "Disk Snapshot Contributor"
      who   = local.aks_backup_vault_principal
    }
    vault_disk_data = {
      scope = azurerm_resource_group.aks_snapshots[0].id
      role  = "Data Operator for Managed Disks"
      who   = local.aks_backup_vault_principal
    }
    vault_blob_reader = {
      scope = azurerm_storage_account.aks_backup[0].id
      role  = "Storage Blob Data Reader"
      who   = local.aks_backup_vault_principal
    }
    cluster_snapshots = {
      scope = azurerm_resource_group.aks_snapshots[0].id
      role  = "Contributor"
      who   = azurerm_user_assigned_identity.aks.principal_id
    }
  } : {}
}

resource "azurerm_role_assignment" "aks_backup" {
  for_each             = local.aks_backup_roles
  scope                = each.value.scope
  role_definition_name = each.value.role
  principal_id         = each.value.who
  principal_type       = "ServicePrincipal"
}

# ── Policy and backup instance ───────────────────────────────────────────────

# Every 4 hours (the service minimum) on the operational store, kept 1 day. The
# drill takes an on-demand backup right before the simulated loss, so the
# schedule is only the stated cadence, not what the drill restores from.
resource "azurerm_data_protection_backup_policy_kubernetes_cluster" "aks_demo" {
  count               = local.backup_count
  name                = "bkpol-${var.project}-aks-demo"
  resource_group_name = azurerm_resource_group.prod.name
  vault_name          = azurerm_data_protection_backup_vault.aks_demo[0].name

  backup_repeating_time_intervals = ["R/2026-01-01T00:00:00+00:00/PT4H"]
  time_zone                       = "UTC"

  default_retention_rule {
    life_cycle {
      duration        = "P1D"
      data_store_type = "OperationalStore"
    }
  }
}

resource "azurerm_data_protection_backup_instance_kubernetes_cluster" "aks_demo" {
  count                        = local.backup_count
  name                         = "bi-${var.project}-slo-data"
  location                     = azurerm_resource_group.prod.location
  vault_id                     = azurerm_data_protection_backup_vault.aks_demo[0].id
  kubernetes_cluster_id        = azurerm_kubernetes_cluster.prod.id
  snapshot_resource_group_name = azurerm_resource_group.aks_snapshots[0].name
  backup_policy_id             = azurerm_data_protection_backup_policy_kubernetes_cluster.aks_demo[0].id

  backup_datasource_parameters {
    included_namespaces = [local.data_namespace]
    # PersistentVolumes are cluster-scoped. Without them the restore would bring
    # back claims with no volume behind them. The restore request still targets
    # only the slo-data namespace.
    cluster_scoped_resources_enabled = true
    volume_snapshot_enabled          = true
  }

  depends_on = [
    azurerm_role_assignment.aks_backup,
    azurerm_kubernetes_cluster_trusted_access_role_binding.aks_backup,
    azurerm_kubernetes_cluster_extension.aks_backup,
  ]
}
