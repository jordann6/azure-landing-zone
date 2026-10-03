# ── Logic App: a scheduled integration ──────────────────────────────────────
# Every morning, pull the daily order summary from the portal API through
# Front Door. It stands in for the integrations a cooperative runs (a nightly
# report to members, a file drop to a wholesaler); run history and failures go
# to the central workspace.

resource "azurerm_logic_app_workflow" "daily_report" {
  name                = "logic-${var.project}-portal-daily-report"
  location            = var.primary_location
  resource_group_name = azurerm_resource_group.edge.name
  tags                = azurerm_resource_group.edge.tags

  identity {
    type = "SystemAssigned"
  }
}

resource "azurerm_logic_app_trigger_recurrence" "daily" {
  name         = "daily-6am-central"
  logic_app_id = azurerm_logic_app_workflow.daily_report.id
  frequency    = "Day"
  interval     = 1
  time_zone    = "Central Standard Time"

  schedule {
    at_these_hours   = [6]
    at_these_minutes = [0]
  }
}

resource "azurerm_logic_app_action_http" "get_report" {
  name         = "get-daily-report"
  logic_app_id = azurerm_logic_app_workflow.daily_report.id
  method       = "GET"
  uri          = "https://${azurerm_cdn_frontdoor_endpoint.portal.host_name}/api/reports/daily"
}

resource "azurerm_monitor_diagnostic_setting" "logic_app" {
  name                       = "diag-logic-app"
  target_resource_id         = azurerm_logic_app_workflow.daily_report.id
  log_analytics_workspace_id = local.law_id

  enabled_log { category = "WorkflowRuntime" }

  metric {
    category = "AllMetrics"
    enabled  = true
  }
}
