# ── Secret age and near-expiry alert ─────────────────────────────────────────
# Key Vault logs SecretNearExpiryEventGridNotification (observed live 2026-10-06)
# to AuditEvent, which the base routes to the central workspace. The Expired
# variants are matched by name and not yet observed.
# This pages the ops action group when one appears, so an aging secret reaches a
# person without anyone running the scanner. test-secrets.sh proves the event and
# the alert end to end.

resource "azurerm_monitor_scheduled_query_rules_alert_v2" "near_expiry" {
  count = var.near_expiry_alert_enabled ? 1 : 0

  name                  = "alert-${var.project}-secret-near-expiry"
  resource_group_name   = local.logging_rg
  location              = var.location
  scopes                = [local.law_id]
  description           = "A Key Vault secret, key or certificate is near expiry or expired."
  severity              = 3
  evaluation_frequency  = "PT15M"
  window_duration       = "PT1H"
  skip_query_validation = true
  tags                  = local.tags

  criteria {
    query                   = <<-KQL
      AzureDiagnostics
      | where ResourceProvider == "MICROSOFT.KEYVAULT"
      | where OperationName contains "NearExpiry" or OperationName contains "ExpiredEventGrid"
    KQL
    time_aggregation_method = "Count"
    operator                = "GreaterThan"
    threshold               = 0
  }

  action {
    action_groups = [local.action_group_id]
  }

  lifecycle {
    precondition {
      condition     = local.base_ready
      error_message = "The base landing zone (terraform/) must be deployed first."
    }
  }
}
