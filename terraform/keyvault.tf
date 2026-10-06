# ── Key Vault + customer-managed key ─────────────────────────────────────────
# RBAC-authorized vault with purge protection and soft delete on. The CMK with a
# rotation policy is the encryption root for the estate (and the ~$1/mo standing
# residual that survives destroy for the soft-delete window, by design).
#
# public_network_access stays enabled so the deploying principal can create the
# key on first apply; the private endpoint (private_endpoints.tf) is the intended
# access path, and in a real prod tier public access is disabled once workloads
# reach the vault privately. That trade-off is documented in the README.

resource "random_string" "kv" {
  length  = 6
  upper   = false
  special = false
}

resource "azurerm_resource_group" "security" {
  name     = "rg-${var.project}-security"
  location = var.location
  tags     = merge(local.tags, { environment = "platform" })
}

resource "azurerm_key_vault" "cmk" {
  name                = "kv-${var.project}-${random_string.kv.result}"
  location            = azurerm_resource_group.security.location
  resource_group_name = azurerm_resource_group.security.name
  tenant_id           = data.azurerm_client_config.current.tenant_id
  sku_name            = "standard"

  rbac_authorization_enabled = true
  purge_protection_enabled   = true
  soft_delete_retention_days = 7

  # Default-deny firewall. AzureServices bypass plus the deployer's own IP is the
  # only allowed path, so the CMK can be created on first apply; workloads reach
  # the vault through the private endpoint (private_endpoints.tf).
  public_network_access_enabled = true
  network_acls {
    default_action = "Deny"
    bypass         = "AzureServices"
    ip_rules       = var.deployer_ip_cidrs
  }

  tags = local.tags

  # checkov:skip=CKV_AZURE_189:Public network access stays on so the deploying
  # principal can create the CMK over the data plane on first apply. Access is
  # still default-Deny (network_acls above); the private endpoint is the intended
  # workload path and a real prod tier flips this to false once workloads are
  # private.
}

# Whoever runs the apply needs Crypto Officer to create and rotate the CMK.
locals {
  kv_admin_object_id = var.kv_admin_object_id != "" ? var.kv_admin_object_id : data.azurerm_client_config.current.object_id
}

resource "azurerm_role_assignment" "kv_admin" {
  scope                = azurerm_key_vault.cmk.id
  role_definition_name = "Key Vault Crypto Officer"
  principal_id         = local.kv_admin_object_id
}

resource "azurerm_key_vault_key" "cmk" {
  name         = "cmk-${var.project}"
  key_vault_id = azurerm_key_vault.cmk.id
  key_type     = "RSA"
  key_size     = 2048

  # checkov:skip=CKV_AZURE_112:An HSM-backed key (RSA-HSM) requires a Premium
  # vault, which bills more than the demo budget allows. This is a
  # software-protected key; the Premium/HSM upgrade is documented in the README.
  # checkov:skip=CKV_AZURE_40:Key lifetime is governed by rotation_policy
  # (expire_after P90D) rather than a static expiration_date, so the key expires
  # and rotates automatically.

  key_opts = [
    "decrypt",
    "encrypt",
    "sign",
    "unwrapKey",
    "verify",
    "wrapKey",
  ]

  rotation_policy {
    automatic {
      time_before_expiry = "P30D"
    }
    expire_after         = "P90D"
    notify_before_expiry = "P29D"
  }

  depends_on = [azurerm_role_assignment.kv_admin]
}
