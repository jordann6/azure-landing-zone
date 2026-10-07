# ── Positive control ─────────────────────────────────────────────────────────
# One inert secret with no expiry date, so the scanner has a known finding to
# report in a vault that would otherwise be empty. The value is deliberately
# not a plausible credential. The deployer needs Secrets Officer to write it,
# which exists only while this root does.

resource "azurerm_role_assignment" "control_writer" {
  count = var.enable_control_secret ? 1 : 0

  scope                = local.cmk_vault_id
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = data.azurerm_client_config.current.object_id
}

resource "azurerm_key_vault_secret" "control" {
  # checkov:skip=CKV_AZURE_41:The missing expiry date is the point. This is the positive control the scanner and the CIS secret-expiry policy must flag.
  # checkov:skip=CKV_AZURE_114:Content type is irrelevant for an inert control value.
  count = var.enable_control_secret ? 1 : 0

  name         = "scanner-positive-control"
  value        = "not-a-real-secret-positive-control"
  key_vault_id = local.cmk_vault_id
  tags         = merge(local.tags, { purpose = "scanner-positive-control" })

  depends_on = [azurerm_role_assignment.control_writer]
}
