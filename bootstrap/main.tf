# Dedicated, hardened Terraform state backend for this landing zone.
#
# Maps the five state backend controls:
#   1. Destruction protection: prevent_destroy on the account and vault, plus a
#      CanNotDelete lock on the resource group.
#   2. Versioning: blob versioning, 30-day blob and container soft delete.
#   3. Encryption: customer-managed key from a dedicated vault, plus
#      infrastructure (double) encryption.
#   4. Access and transport: HTTPS only, TLS 1.2, no public blobs, shared keys
#      disabled so every call is Entra ID + RBAC.
#   5. Locking: the azurerm backend's native blob lease. No extra service.
#
# This root is never part of make destroy. It is the one standing piece.

locals {
  tags = {
    project             = "azure-landing-zone"
    owner               = "jordann6"
    managed_by          = "terraform"
    cost_center         = "platform"
    environment         = "shared"
    data_classification = "confidential"
  }

  # Storage firewall IP rules take bare addresses for single hosts, not /32.
  storage_ip_rules = [for cidr in var.deployer_ip_cidrs : trimsuffix(cidr, "/32")]
}

data "azurerm_client_config" "current" {}

resource "azurerm_resource_group" "state" {
  name     = "rg-alz-tfstate"
  location = var.location
  tags     = local.tags
}

# ── Encryption key ───────────────────────────────────────────────────────────

resource "azurerm_user_assigned_identity" "state" {
  name                = "id-alz-tfstate"
  location            = azurerm_resource_group.state.location
  resource_group_name = azurerm_resource_group.state.name
  tags                = local.tags
}

resource "azurerm_key_vault" "state" {
  name                = var.key_vault_name
  location            = azurerm_resource_group.state.location
  resource_group_name = azurerm_resource_group.state.name
  tenant_id           = data.azurerm_client_config.current.tenant_id
  sku_name            = "standard"

  rbac_authorization_enabled = true
  purge_protection_enabled   = true
  soft_delete_retention_days = 90

  # Storage reaches the key as a trusted Azure service; the deployer reaches it
  # from an allowlisted IP to create the key.
  public_network_access_enabled = true
  network_acls {
    default_action = "Deny"
    bypass         = "AzureServices"
    ip_rules       = var.deployer_ip_cidrs
  }

  tags = local.tags

  # checkov:skip=CKV_AZURE_189:Public network access stays on so the deployer
  # can create the key over the data plane. The firewall default-denies; only
  # trusted Azure services and deployer_ip_cidrs get through.
  # checkov:skip=CKV2_AZURE_32:A private endpoint would need a standing VNet
  # and private DNS zone that outlive every session. The firewall plus RBAC is
  # the control here.

  lifecycle {
    prevent_destroy = true
  }
}

resource "azurerm_role_assignment" "deployer_crypto_officer" {
  scope                = azurerm_key_vault.state.id
  role_definition_name = "Key Vault Crypto Officer"
  principal_id         = data.azurerm_client_config.current.object_id
}

resource "azurerm_role_assignment" "state_identity_crypto_user" {
  scope                = azurerm_key_vault.state.id
  role_definition_name = "Key Vault Crypto Service Encryption User"
  principal_id         = azurerm_user_assigned_identity.state.principal_id
}

# RBAC assignments take a minute to reach the data plane.
resource "time_sleep" "rbac_propagation" {
  create_duration = "90s"

  depends_on = [
    azurerm_role_assignment.deployer_crypto_officer,
    azurerm_role_assignment.state_identity_crypto_user,
  ]
}

resource "azurerm_key_vault_key" "state" {
  name         = "cmk-alz-tfstate"
  key_vault_id = azurerm_key_vault.state.id
  key_type     = "RSA"
  key_size     = 2048
  key_opts     = ["unwrapKey", "wrapKey"]

  # checkov:skip=CKV_AZURE_112:An HSM-backed key needs a Premium vault. This is
  # a software-protected key, same as the landing zone CMK.
  # checkov:skip=CKV_AZURE_40:Lifetime is governed by rotation_policy. The key
  # rotates every 90 days, well inside its 2-year expiry, and the account uses
  # the versionless key ID so it follows each rotation.

  rotation_policy {
    automatic {
      time_after_creation = "P90D"
    }
    expire_after         = "P2Y"
    notify_before_expiry = "P30D"
  }

  depends_on = [time_sleep.rbac_propagation]
}

# ── State storage ────────────────────────────────────────────────────────────

resource "azurerm_storage_account" "state" {
  name                     = var.storage_account_name
  resource_group_name      = azurerm_resource_group.state.name
  location                 = azurerm_resource_group.state.location
  account_kind             = "StorageV2"
  account_tier             = "Standard"
  account_replication_type = "GRS"
  # v4 flips the default to false; the live account was created with v3 (true).
  # Explicit false is the intended hardening and the only in-place change in the upgrade.
  cross_tenant_replication_enabled = false

  min_tls_version                   = "TLS1_2"
  https_traffic_only_enabled        = true
  allow_nested_items_to_be_public   = false
  shared_access_key_enabled         = false
  default_to_oauth_authentication   = true
  local_user_enabled                = false
  infrastructure_encryption_enabled = true
  public_network_access_enabled     = true

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.state.id]
  }

  customer_managed_key {
    key_vault_key_id          = azurerm_key_vault_key.state.versionless_id
    user_assigned_identity_id = azurerm_user_assigned_identity.state.id
  }

  blob_properties {
    versioning_enabled = true

    delete_retention_policy {
      days = 30
    }

    container_delete_retention_policy {
      days = 30
    }
  }

  network_rules {
    # trivy:ignore:AVD-AZU-0012 Allow by default, behind Entra-only auth; see CKV_AZURE_35 below.
    default_action = var.network_default_action
    bypass         = ["AzureServices"]
    ip_rules       = local.storage_ip_rules
  }

  tags = local.tags

  # checkov:skip=CKV_AZURE_35:Default action is a variable, Allow by default.
  # Shared keys are disabled, so every request needs an Entra ID token and a
  # Storage Blob Data role; identity is the perimeter. An IP allowlist on a
  # dynamic home IP locked the landing zone's own Key Vault (ForbiddenByFirewall).
  # Set network_default_action = "Deny" to add the allowlist. See the ADR.
  # checkov:skip=CKV_AZURE_59:Same reason as CKV_AZURE_35.
  # checkov:skip=CKV2_AZURE_33:A private endpoint needs a standing VNet and DNS
  # zone that would outlive every session; see CKV_AZURE_35.
  # checkov:skip=CKV2_AZURE_41:Shared keys are disabled, so no SAS token can be
  # signed with an account key and a SAS expiration policy has nothing to govern.
  # checkov:skip=CKV_AZURE_33:No queues exist on this account; it holds state blobs only.

  lifecycle {
    prevent_destroy = true
  }
}

resource "azurerm_role_assignment" "deployer_blob_contributor" {
  scope                = azurerm_storage_account.state.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = data.azurerm_client_config.current.object_id
}

resource "time_sleep" "blob_rbac_propagation" {
  create_duration = "90s"
  depends_on      = [azurerm_role_assignment.deployer_blob_contributor]
}

resource "azurerm_storage_container" "tfstate" {
  name                  = "tfstate"
  storage_account_name  = azurerm_storage_account.state.name
  container_access_type = "private"

  # checkov:skip=CKV2_AZURE_21:Blob read logging would need a standing Log
  # Analytics workspace; the landing zone's workspace is destroyed between
  # sessions. Versioning and soft delete are the recovery controls.

  depends_on = [time_sleep.blob_rbac_propagation]
}

# Noncurrent versions pile up on every apply. Keep 90 days of history.
resource "azurerm_storage_management_policy" "state" {
  storage_account_id = azurerm_storage_account.state.id

  rule {
    name    = "expire-old-state-versions"
    enabled = true
    filters {
      blob_types = ["blockBlob"]
    }
    actions {
      version {
        delete_after_days_since_creation = 90
      }
    }
  }
}

# Blocks deleting the group or anything in it (including from the portal or
# CLI) until the lock is removed on purpose. Writes are unaffected.
resource "azurerm_management_lock" "state" {
  name       = "state-backend-cannot-delete"
  scope      = azurerm_resource_group.state.id
  lock_level = "CanNotDelete"
  notes      = "Terraform state for azure-landing-zone. Remove deliberately, never as part of a session teardown."

  depends_on = [
    azurerm_storage_container.tfstate,
    azurerm_storage_management_policy.state,
    azurerm_key_vault_key.state,
  ]
}
