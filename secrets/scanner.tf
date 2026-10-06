# ── Secrets scanner identity ─────────────────────────────────────────────────
# The Azure secrets lifecycle scanner (azure-secrets-lifecycle) sweeps Key Vault
# metadata: names, creation and expiry dates, tags, rotation policy. It never
# needs a value, and here it cannot read one. That is enforced by the role, not
# by careful code: Key Vault Reader carries
# Microsoft.KeyVault/vaults/secrets/readMetadata/action and does not carry
# .../secrets/getSecret/action. This is the Azure counterpart of the AWS scanner
# role that lists secrets but is denied GetSecretValue.

resource "azurerm_resource_group" "secrets" {
  name     = "rg-${var.project}-secrets"
  location = var.location
  tags     = local.tags
}

resource "azurerm_user_assigned_identity" "scanner" {
  name                = "id-${var.project}-secrets-scanner"
  resource_group_name = azurerm_resource_group.secrets.name
  location            = azurerm_resource_group.secrets.location
  tags                = local.tags
}

# Data-plane metadata on every landing-zone vault, scoped to the vault itself.
resource "azurerm_role_assignment" "scanner_vault_reader" {
  for_each = local.vaults

  scope                = each.value
  role_definition_name = "Key Vault Reader"
  principal_id         = azurerm_user_assigned_identity.scanner.principal_id

  lifecycle {
    precondition {
      condition     = local.base_ready
      error_message = "The base landing zone (terraform/) must be deployed first: key_vault_id is missing from its state."
    }
  }
}

# The scanner discovers vaults with a subscription-wide resource list, so it
# needs Reader. Reader is control plane only and grants no data actions.
resource "azurerm_role_assignment" "scanner_reader" {
  scope                = data.azurerm_subscription.current.id
  role_definition_name = "Reader"
  principal_id         = azurerm_user_assigned_identity.scanner.principal_id
}

# Audit events for the consumer map, the same workspace everything else uses.
resource "azurerm_role_assignment" "scanner_log_reader" {
  scope                = local.law_id
  role_definition_name = "Log Analytics Reader"
  principal_id         = azurerm_user_assigned_identity.scanner.principal_id
}

# The data-tier vault has no diagnostic setting of its own, so its secret
# events (including near-expiry) would never reach the workspace.
resource "azurerm_monitor_diagnostic_setting" "workload_vault" {
  count = local.workload_vault_id == null ? 0 : 1

  name                       = "diag-keyvault-secrets"
  target_resource_id         = local.workload_vault_id
  log_analytics_workspace_id = local.law_id

  enabled_log {
    category = "AuditEvent"
  }
}
