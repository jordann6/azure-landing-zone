# ── Alerting ─────────────────────────────────────────────────────────────────
# Logging without alerting is a record nobody reads until after the incident.
# One action group, and a small set of alerts chosen because each one means a
# person should look now:
#
#   - a Deny policy blocked a request (someone tried something the guardrails
#     forbid; usually a mistake, occasionally not)
#   - Key Vault refused a request (an identity reached for a secret or key it
#     is not allowed to use)
#   - the hub firewall's deny count spiked (something new is trying to get out)
#
# Log alert rules bill per rule per month (cents at a 15-minute frequency) and
# are destroyed with the stack. The queries also live in docs/kql/ so the same
# investigation can be run by hand.

resource "azurerm_monitor_action_group" "ops" {
  name                = "ag-${var.project}-ops"
  resource_group_name = azurerm_resource_group.logging.name
  short_name          = "alz-ops"
  tags                = local.tags

  email_receiver {
    name                    = "owner"
    email_address           = var.alert_email
    use_common_alert_schema = true
  }
}

# Activity log alert: any Deny policy effect anywhere in the subscription.
resource "azurerm_monitor_activity_log_alert" "policy_deny" {
  name                = "alert-${var.project}-policy-deny"
  resource_group_name = azurerm_resource_group.logging.name
  scopes              = [data.azurerm_subscription.current.id]
  description         = "A request was blocked by a Deny policy (public IP, region, tags, phi network access)."
  tags                = local.tags

  criteria {
    category       = "Policy"
    operation_name = "Microsoft.Authorization/policies/deny/action"
  }

  action {
    action_group_id = azurerm_monitor_action_group.ops.id
  }
}

# Log alert: Key Vault returned Forbidden. Key Vault diagnostics land in the
# AzureDiagnostics table (monitoring.tf). skip_query_validation because the
# table does not exist in a fresh workspace until the first event arrives.
resource "azurerm_monitor_scheduled_query_rules_alert_v2" "kv_forbidden" {
  name                  = "alert-${var.project}-kv-forbidden"
  resource_group_name   = azurerm_resource_group.logging.name
  location              = azurerm_resource_group.logging.location
  scopes                = [azurerm_log_analytics_workspace.central.id]
  description           = "Key Vault refused one or more requests (403) in the last 15 minutes."
  severity              = 2
  evaluation_frequency  = "PT15M"
  window_duration       = "PT15M"
  skip_query_validation = true
  tags                  = local.tags

  criteria {
    query                   = <<-KQL
      AzureDiagnostics
      | where ResourceProvider == "MICROSOFT.KEYVAULT"
      | where ResultSignature == "Forbidden"
    KQL
    time_aggregation_method = "Count"
    operator                = "GreaterThan"
    threshold               = 0
  }

  action {
    action_groups = [azurerm_monitor_action_group.ops.id]
  }
}

# Log alert: hub firewall deny spike. Only meaningful while the firewall exists,
# so it follows the same flag.
resource "azurerm_monitor_scheduled_query_rules_alert_v2" "firewall_deny_spike" {
  count = local.fw_azure_count

  name                  = "alert-${var.project}-fw-deny-spike"
  resource_group_name   = azurerm_resource_group.logging.name
  location              = azurerm_resource_group.logging.location
  scopes                = [azurerm_log_analytics_workspace.central.id]
  description           = "The hub firewall denied more than ${var.firewall_deny_alert_threshold} connections in 15 minutes."
  severity              = 3
  evaluation_frequency  = "PT15M"
  window_duration       = "PT15M"
  skip_query_validation = true
  tags                  = local.tags

  criteria {
    query                   = <<-KQL
      union isfuzzy=true AZFWNetworkRule, AZFWApplicationRule
      | where Action == "Deny"
    KQL
    time_aggregation_method = "Count"
    operator                = "GreaterThan"
    threshold               = var.firewall_deny_alert_threshold
  }

  action {
    action_groups = [azurerm_monitor_action_group.ops.id]
  }
}
