# Workload data-tier key material. One Key Vault holds the customer-managed keys
# that protect the paved road: the AKS etcd KMS key (envelope-encrypts Kubernetes
# secrets), the node OS-disk key (via a disk encryption set), and the data key for
# the PostgreSQL server and the container registry. Mirrors the separate data CMK
# family in aws-landing-zone/workload/kms.tf; here one vault, several keys.

resource "random_string" "kv" {
  length  = 6
  upper   = false
  special = false
}

resource "azurerm_key_vault" "workload" {
  # checkov:skip=CKV_AZURE_189:Public network access stays on (ACL default-Deny + AzureServices bypass + deployer IP) so the deployer can create the keys and the DB secret over the data plane on first apply. Workloads, including the AKS etcd KMS (key_vault_network_access=Private), reach the vault over the private endpoint; disabling public access entirely (deploying from inside the network) is the production upgrade.
  name                       = "kv-${var.project}-wl-${random_string.kv.result}"
  location                   = azurerm_resource_group.prod.location
  resource_group_name        = azurerm_resource_group.prod.name
  tenant_id                  = data.azurerm_client_config.current.tenant_id
  sku_name                   = "standard"
  rbac_authorization_enabled = true
  purge_protection_enabled   = true
  soft_delete_retention_days = 7
  tags                       = local.tags

  network_acls {
    default_action = "Deny"
    bypass         = "AzureServices"
    ip_rules       = var.deployer_ip_cidrs
  }
}

# The deployer needs crypto-officer rights to create the keys on first apply.
resource "azurerm_role_assignment" "kv_deployer" {
  scope                = azurerm_key_vault.workload.id
  role_definition_name = "Key Vault Crypto Officer"
  principal_id         = data.azurerm_client_config.current.object_id
}

resource "azurerm_key_vault_key" "etcd" {
  # checkov:skip=CKV_AZURE_40:Expiry is enforced via the rotation policy (expire_after P90D), not a static expiration_date.
  # checkov:skip=CKV_AZURE_112:Software-protected key on the Standard tier; an HSM-backed key (Premium/Managed HSM) is the production upgrade.
  name         = "aks-etcd-cmk"
  key_vault_id = azurerm_key_vault.workload.id
  key_type     = "RSA"
  key_size     = 2048
  key_opts     = ["decrypt", "encrypt", "sign", "unwrapKey", "verify", "wrapKey"]

  rotation_policy {
    automatic { time_before_expiry = "P30D" }
    expire_after         = "P90D"
    notify_before_expiry = "P29D"
  }

  depends_on = [azurerm_role_assignment.kv_deployer]
}

resource "azurerm_key_vault_key" "data" {
  # checkov:skip=CKV_AZURE_40:Expiry is enforced via the rotation policy (expire_after P90D), not a static expiration_date.
  # checkov:skip=CKV_AZURE_112:Software-protected key on the Standard tier; an HSM-backed key (Premium/Managed HSM) is the production upgrade.
  name         = "data-tier-cmk"
  key_vault_id = azurerm_key_vault.workload.id
  key_type     = "RSA"
  key_size     = 2048
  key_opts     = ["decrypt", "encrypt", "sign", "unwrapKey", "verify", "wrapKey"]

  rotation_policy {
    automatic { time_before_expiry = "P30D" }
    expire_after         = "P90D"
    notify_before_expiry = "P29D"
  }

  depends_on = [azurerm_role_assignment.kv_deployer]
}

resource "azurerm_key_vault_key" "disk" {
  # checkov:skip=CKV_AZURE_40:Expiry is enforced via the rotation policy (expire_after P90D), not a static expiration_date.
  # checkov:skip=CKV_AZURE_112:Software-protected key on the Standard tier; an HSM-backed key (Premium/Managed HSM) is the production upgrade.
  name         = "aks-node-disk-cmk"
  key_vault_id = azurerm_key_vault.workload.id
  key_type     = "RSA"
  key_size     = 2048
  key_opts     = ["decrypt", "encrypt", "sign", "unwrapKey", "verify", "wrapKey"]

  rotation_policy {
    automatic { time_before_expiry = "P30D" }
    expire_after         = "P90D"
    notify_before_expiry = "P29D"
  }

  depends_on = [azurerm_role_assignment.kv_deployer]
}

# Disk encryption set: CMK for the AKS node OS/data disks. Its managed identity is
# granted crypto rights on the vault so the platform can wrap/unwrap the disk keys.
resource "azurerm_disk_encryption_set" "aks" {
  name                = "des-${var.project}-aks"
  location            = azurerm_resource_group.prod.location
  resource_group_name = azurerm_resource_group.prod.name
  key_vault_key_id    = azurerm_key_vault_key.disk.id
  tags                = local.tags

  identity {
    type = "SystemAssigned"
  }
}

resource "azurerm_role_assignment" "des_kv" {
  scope                = azurerm_key_vault.workload.id
  role_definition_name = "Key Vault Crypto Service Encryption User"
  principal_id         = azurerm_disk_encryption_set.aks.identity[0].principal_id
}
