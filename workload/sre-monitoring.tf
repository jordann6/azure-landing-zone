# Metrics path for the SRE demo: managed Prometheus on AKS (ama-metrics)
# remote-writes to an Azure Monitor workspace through a data collection endpoint
# and rule. Recording and alert rules for the SLO run in the workspace as
# Prometheus rule groups and page through the base landing zone's ops action
# group. Dashboards are served by the in-cluster Grafana (gitops/apps/grafana),
# which reads this workspace over workload identity.
#
# Severity contract (docs/slo.md): Sev 1 = page, Sev 3 = ticket. Both deliver as
# email from ag-<project>-ops today; the alert history is the receipt.

locals {
  ops_action_group_id = try(data.terraform_remote_state.base.outputs.ops_action_group_id, null)

  # Objective 99.5% over 30 days, so the error budget is 0.5% of requests.
  slo_error_budget = 0.005
  fast_burn_rate   = 14.4
  slow_burn_rate   = 6

  # Requests the SLI counts. The app does not instrument /healthz, /readyz or
  # /metrics, so probes and scrapes never enter the ratio.
  sli_selector = "namespace=\"${local.app_namespace}\""

  sli_windows = ["5m", "30m", "1h", "6h"]
}

resource "azurerm_monitor_workspace" "sre" {
  count               = local.sre_count
  name                = "amw-${var.project}-prod"
  resource_group_name = azurerm_resource_group.prod.name
  location            = azurerm_resource_group.prod.location
  tags                = local.tags
}

resource "azurerm_monitor_data_collection_endpoint" "sre" {
  count               = local.sre_count
  name                = "dce-${var.project}-prom"
  resource_group_name = azurerm_resource_group.prod.name
  location            = azurerm_resource_group.prod.location
  kind                = "Linux"
  tags                = local.tags
}

resource "azurerm_monitor_data_collection_rule" "sre" {
  count                       = local.sre_count
  name                        = "dcr-${var.project}-prom"
  resource_group_name         = azurerm_resource_group.prod.name
  location                    = azurerm_resource_group.prod.location
  kind                        = "Linux"
  data_collection_endpoint_id = azurerm_monitor_data_collection_endpoint.sre[0].id
  tags                        = local.tags

  destinations {
    monitor_account {
      monitor_account_id = azurerm_monitor_workspace.sre[0].id
      name               = "amw"
    }
  }

  data_flow {
    streams      = ["Microsoft-PrometheusMetrics"]
    destinations = ["amw"]
  }

  data_sources {
    prometheus_forwarder {
      streams = ["Microsoft-PrometheusMetrics"]
      name    = "PrometheusDataSource"
    }
  }
}

resource "azurerm_monitor_data_collection_rule_association" "sre" {
  count                   = local.sre_count
  name                    = "dcra-${var.project}-prom"
  target_resource_id      = azurerm_kubernetes_cluster.prod.id
  data_collection_rule_id = azurerm_monitor_data_collection_rule.sre[0].id
}

# The add-on discovers its endpoint through this fixed-name association.
resource "azurerm_monitor_data_collection_rule_association" "sre_endpoint" {
  count                       = local.sre_count
  name                        = "configurationAccessEndpoint"
  target_resource_id          = azurerm_kubernetes_cluster.prod.id
  data_collection_endpoint_id = azurerm_monitor_data_collection_endpoint.sre[0].id
}

# Recording rules: total request rate and 5xx ratio over each SLO window.
resource "azurerm_monitor_alert_prometheus_rule_group" "slo_recording" {
  count               = local.sre_count
  name                = "prg-${var.project}-slo-recording"
  resource_group_name = azurerm_resource_group.prod.name
  location            = azurerm_resource_group.prod.location
  cluster_name        = azurerm_kubernetes_cluster.prod.name
  description         = "SLI recording rules for slo-demo: request rate and 5xx ratio per window."
  rule_group_enabled  = true
  interval            = "PT1M"
  scopes              = [azurerm_monitor_workspace.sre[0].id]
  tags                = local.tags

  dynamic "rule" {
    for_each = local.sli_windows
    content {
      enabled    = true
      record     = "slo:requests:rate${rule.value}"
      expression = "sum(rate(slo_demo_requests_total{${local.sli_selector}}[${rule.value}]))"
    }
  }

  dynamic "rule" {
    for_each = local.sli_windows
    content {
      enabled    = true
      record     = "slo:errors:ratio_rate${rule.value}"
      expression = "sum(rate(slo_demo_requests_total{${local.sli_selector},code_class=\"5xx\"}[${rule.value}])) / sum(rate(slo_demo_requests_total{${local.sli_selector}}[${rule.value}]))"
    }
  }
}

# Multiwindow, multi-burn-rate alerts (Google SRE workbook, chapter 5), plus two
# guards so missing data never reads as healthy: no traffic, and no live target.
#
# No rule sets `for`. The burn-rate pairs do not need it (the short window is the
# reset), the guards carry their hold time in the range vector, and Checkov's HCL
# parser fails on an attribute named `for`, which silently drops the whole file
# from the security scan.
resource "azurerm_monitor_alert_prometheus_rule_group" "slo_alerts" {
  count               = local.sre_count
  name                = "prg-${var.project}-slo-alerts"
  resource_group_name = azurerm_resource_group.prod.name
  location            = azurerm_resource_group.prod.location
  cluster_name        = azurerm_kubernetes_cluster.prod.name
  description         = "SLO burn-rate and data-presence alerts for slo-demo."
  rule_group_enabled  = true
  interval            = "PT1M"
  scopes              = [azurerm_monitor_workspace.sre[0].id]
  tags                = local.tags

  rule {
    enabled    = true
    alert      = "SloFastBurn"
    severity   = 1
    expression = "slo:errors:ratio_rate1h > ${local.fast_burn_rate * local.slo_error_budget} and slo:errors:ratio_rate5m > ${local.fast_burn_rate * local.slo_error_budget}"
    labels     = { slo = "slo-demo-availability", page = "true" }
    annotations = {
      summary     = "slo-demo is burning its 30-day error budget at over 14.4x (2% of budget per hour)."
      runbook_url = "${var.slo_alert_runbook_base_url}/slo-fast-burn.md"
    }
    action {
      action_group_id = local.ops_action_group_id
    }
    alert_resolution {
      auto_resolved   = true
      time_to_resolve = "PT5M"
    }
  }

  rule {
    enabled    = true
    alert      = "SloSlowBurn"
    severity   = 3
    expression = "slo:errors:ratio_rate6h > ${local.slow_burn_rate * local.slo_error_budget} and slo:errors:ratio_rate30m > ${local.slow_burn_rate * local.slo_error_budget}"
    labels     = { slo = "slo-demo-availability", ticket = "true" }
    annotations = {
      summary     = "slo-demo is burning its 30-day error budget at over 6x (5% of budget in 6 hours)."
      runbook_url = "${var.slo_alert_runbook_base_url}/slo-slow-burn.md"
    }
    action {
      action_group_id = local.ops_action_group_id
    }
    alert_resolution {
      auto_resolved   = true
      time_to_resolve = "PT10M"
    }
  }

  rule {
    enabled    = true
    alert      = "SloNoTraffic"
    severity   = 3
    expression = "(sum(rate(slo_demo_requests_total{${local.sli_selector}}[5m])) or vector(0)) == 0"
    labels     = { slo = "slo-demo-availability", ticket = "true" }
    annotations = {
      summary     = "slo-demo is receiving no requests, so its error ratio is undefined. This is not a healthy reading."
      runbook_url = "${var.slo_alert_runbook_base_url}/slo-no-data.md"
    }
    action {
      action_group_id = local.ops_action_group_id
    }
    alert_resolution {
      auto_resolved   = true
      time_to_resolve = "PT5M"
    }
  }

  rule {
    enabled    = true
    alert      = "SloTargetsDown"
    severity   = 1
    expression = "(count(max_over_time(up{${local.sli_selector}}[3m]) == 1) or vector(0)) < 1"
    labels     = { slo = "slo-demo-availability", page = "true" }
    annotations = {
      summary     = "No slo-demo scrape target is up. Burn-rate alerts cannot fire without data."
      runbook_url = "${var.slo_alert_runbook_base_url}/slo-no-data.md"
    }
    action {
      action_group_id = local.ops_action_group_id
    }
    alert_resolution {
      auto_resolved   = true
      time_to_resolve = "PT5M"
    }
  }
}

# The operator queries the workspace from the drill scripts (PromQL over the
# query endpoint). Owner does not include data actions, so the read is explicit.
resource "azurerm_role_assignment" "deployer_amw_reader" {
  count                = local.sre_count
  scope                = azurerm_monitor_workspace.sre[0].id
  role_definition_name = "Monitoring Data Reader"
  principal_id         = data.azurerm_client_config.current.object_id
}
