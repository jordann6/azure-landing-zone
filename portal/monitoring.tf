# ── Observability for the portal ────────────────────────────────────────────
# Application Insights (workspace-based, so everything lands in the base
# landing zone's central workspace), an availability test from five US
# locations through Front Door, one SLO with a burn-rate alert, the alerts an
# on-call person would want for this app, and a workbook that puts it on one
# page. Every alert routes to the base ops action group.

resource "azurerm_application_insights" "portal" {
  name                = "appi-${var.project}-portal"
  location            = var.primary_location
  resource_group_name = azurerm_resource_group.edge.name
  workspace_id        = local.law_id
  application_type    = "web"
  tags                = azurerm_resource_group.edge.tags
}

# Synthetic check of the real user path: public internet -> Front Door -> WAF
# -> Private Link -> Container Apps -> SQL. /health returns 503 if the app
# cannot reach the database, so this measures what a member would see.
resource "azurerm_application_insights_standard_web_test" "health" {
  name                    = "webtest-portal-health"
  resource_group_name     = azurerm_resource_group.edge.name
  location                = var.primary_location
  application_insights_id = azurerm_application_insights.portal.id
  geo_locations           = var.availability_test_locations
  frequency               = 300
  timeout                 = 30
  enabled                 = true

  # Azure links a web test to its component through this hidden tag.
  tags = merge(azurerm_resource_group.edge.tags, {
    "hidden-link:${azurerm_application_insights.portal.id}" = "Resource"
  })

  request {
    url = "https://${azurerm_cdn_frontdoor_endpoint.portal.host_name}/health"
  }

  validation_rules {
    expected_status_code        = 200
    ssl_check_enabled           = true
    ssl_cert_remaining_lifetime = 7
  }
}

# Page when two or more test locations fail at once (one location failing is
# usually that location's network, not the portal).
resource "azurerm_monitor_metric_alert" "availability" {
  name                = "alert-portal-availability"
  resource_group_name = azurerm_resource_group.edge.name
  scopes              = [azurerm_application_insights_standard_web_test.health.id, azurerm_application_insights.portal.id]
  description         = "The portal health check is failing from two or more locations."
  severity            = 1
  frequency           = "PT1M"
  window_size         = "PT5M"
  tags                = azurerm_resource_group.edge.tags

  application_insights_web_test_location_availability_criteria {
    web_test_id           = azurerm_application_insights_standard_web_test.health.id
    component_id          = azurerm_application_insights.portal.id
    failed_location_count = 2
  }

  action {
    action_group_id = local.ops_action_group_id
  }
}

# SLO: 99.9% of availability checks succeed (error budget 0.1%). Fast-burn
# alert: if the last hour's failure rate exceeds 14.4x the budget, the whole
# month's budget would be gone in about two days. Alerting on burn rate pages
# on real user impact instead of every blip.
resource "azurerm_monitor_scheduled_query_rules_alert_v2" "slo_fast_burn" {
  name                  = "alert-portal-slo-fast-burn"
  resource_group_name   = azurerm_resource_group.edge.name
  location              = var.primary_location
  scopes                = [local.law_id]
  description           = "Portal availability SLO (99.9%) is burning error budget at more than 14.4x in the last hour."
  severity              = 1
  evaluation_frequency  = "PT5M"
  window_duration       = "PT1H"
  skip_query_validation = true
  tags                  = azurerm_resource_group.edge.tags

  criteria {
    query                   = <<-KQL
      AppAvailabilityResults
      | where Name == "${azurerm_application_insights_standard_web_test.health.name}"
      | summarize total = count(), failed = countif(Success == false)
      | extend error_rate = todouble(failed) / todouble(total)
      | where total > 0 and error_rate > 0.0144
    KQL
    time_aggregation_method = "Count"
    operator                = "GreaterThan"
    threshold               = 0
  }

  action {
    action_groups = [local.ops_action_group_id]
  }
}

# Front Door: server errors as a percentage of requests.
resource "azurerm_monitor_metric_alert" "frontdoor_5xx" {
  name                = "alert-portal-frontdoor-5xx"
  resource_group_name = azurerm_resource_group.edge.name
  scopes              = [azurerm_cdn_frontdoor_profile.portal.id]
  description         = "More than 5% of portal requests returned 5xx in the last 5 minutes."
  severity            = 2
  frequency           = "PT1M"
  window_size         = "PT5M"
  tags                = azurerm_resource_group.edge.tags

  criteria {
    metric_namespace = "Microsoft.Cdn/profiles"
    metric_name      = "Percentage5XX"
    aggregation      = "Average"
    operator         = "GreaterThan"
    threshold        = 5
  }

  action {
    action_group_id = local.ops_action_group_id
  }
}

# Front Door: an origin (region) is failing its health probes. This fires
# during a regional failover, which is the point: someone should know.
resource "azurerm_monitor_metric_alert" "origin_health" {
  name                = "alert-portal-origin-health"
  resource_group_name = azurerm_resource_group.edge.name
  scopes              = [azurerm_cdn_frontdoor_profile.portal.id]
  description         = "A portal region is failing Front Door health probes; traffic is shifting to the other region."
  severity            = 2
  frequency           = "PT1M"
  window_size         = "PT5M"
  tags                = azurerm_resource_group.edge.tags

  criteria {
    metric_namespace = "Microsoft.Cdn/profiles"
    metric_name      = "OriginHealthPercentage"
    aggregation      = "Average"
    operator         = "LessThan"
    threshold        = 100
  }

  action {
    action_group_id = local.ops_action_group_id
  }
}

# The SQL failover group changed primary (planned or not).
resource "azurerm_monitor_activity_log_alert" "sql_failover" {
  name                = "alert-portal-sql-failover"
  resource_group_name = azurerm_resource_group.edge.name
  scopes              = [azurerm_resource_group.data.id]
  description         = "The portal SQL failover group switched its primary server."
  tags                = azurerm_resource_group.edge.tags

  criteria {
    category       = "Administrative"
    operation_name = "Microsoft.Sql/servers/failoverGroups/failover/action"
  }

  action {
    action_group_id = local.ops_action_group_id
  }
}

# A region's app is crash-looping.
resource "azurerm_monitor_metric_alert" "app_restarts" {
  for_each = local.regions

  name                = "alert-portal-restarts-${each.value.short}"
  resource_group_name = azurerm_resource_group.edge.name
  scopes              = [azurerm_container_app.portal[each.key].id]
  description         = "The ${each.value.short} portal app restarted more than 3 times in 15 minutes."
  severity            = 2
  frequency           = "PT5M"
  window_size         = "PT15M"
  tags                = azurerm_resource_group.edge.tags

  criteria {
    metric_namespace = "Microsoft.App/containerApps"
    metric_name      = "RestartCount"
    aggregation      = "Total"
    operator         = "GreaterThan"
    threshold        = 3
  }

  action {
    action_group_id = local.ops_action_group_id
  }
}

# WAF blocking a burst of requests: an attack, a bot, or a false positive on a
# new feature. Either way, look.
resource "azurerm_monitor_scheduled_query_rules_alert_v2" "waf_blocks" {
  name                  = "alert-portal-waf-blocks"
  resource_group_name   = azurerm_resource_group.edge.name
  location              = var.primary_location
  scopes                = [local.law_id]
  description           = "The portal WAF blocked more than 100 requests in 15 minutes."
  severity              = 3
  evaluation_frequency  = "PT15M"
  window_duration       = "PT15M"
  skip_query_validation = true
  tags                  = azurerm_resource_group.edge.tags

  criteria {
    query                   = <<-KQL
      AzureDiagnostics
      | where Category == "FrontDoorWebApplicationFirewallLog"
      | where action_s == "Block"
    KQL
    time_aggregation_method = "Count"
    operator                = "GreaterThan"
    threshold               = 100
  }

  action {
    action_groups = [local.ops_action_group_id]
  }
}

# ── Operations workbook ─────────────────────────────────────────────────────
resource "random_uuid" "workbook" {}

resource "azurerm_application_insights_workbook" "portal" {
  name                = random_uuid.workbook.result
  resource_group_name = azurerm_resource_group.edge.name
  location            = var.primary_location
  display_name        = "Member portal operations"
  source_id           = lower(local.law_id)
  tags                = azurerm_resource_group.edge.tags

  data_json = jsonencode({
    version = "Notebook/1.0"
    items = [
      {
        type    = 1
        content = { json = "## Member portal operations\nAvailability, edge traffic, security events, and data-tier changes for the portal, from the central Log Analytics workspace." }
        name    = "header"
      },
      {
        type = 3
        content = {
          version       = "KqlItem/1.0"
          title         = "Availability by test location (last 24h)"
          query         = "AppAvailabilityResults\n| where TimeGenerated > ago(24h)\n| summarize availability = 100.0 * countif(Success == true) / count() by bin(TimeGenerated, 15m), Location"
          size          = 0
          queryType     = 0
          resourceType  = "microsoft.operationalinsights/workspaces"
          visualization = "timechart"
        }
        name = "availability"
      },
      {
        type = 3
        content = {
          version       = "KqlItem/1.0"
          title         = "Front Door requests by status code (last 24h)"
          query         = "AzureDiagnostics\n| where Category == \"FrontDoorAccessLog\" and TimeGenerated > ago(24h)\n| summarize requests = count() by bin(TimeGenerated, 15m), status = tostring(httpStatusCode_s)"
          size          = 0
          queryType     = 0
          resourceType  = "microsoft.operationalinsights/workspaces"
          visualization = "timechart"
        }
        name = "edge-traffic"
      },
      {
        type = 3
        content = {
          version       = "KqlItem/1.0"
          title         = "WAF blocks by rule (last 24h)"
          query         = "AzureDiagnostics\n| where Category == \"FrontDoorWebApplicationFirewallLog\" and action_s == \"Block\" and TimeGenerated > ago(24h)\n| summarize blocks = count() by ruleName_s\n| order by blocks desc"
          size          = 0
          queryType     = 0
          resourceType  = "microsoft.operationalinsights/workspaces"
          visualization = "table"
        }
        name = "waf"
      },
      {
        type = 3
        content = {
          version       = "KqlItem/1.0"
          title         = "Deny policy events (last 7d)"
          query         = "AzureActivity\n| where TimeGenerated > ago(7d) and CategoryValue == \"Policy\" and OperationNameValue =~ \"Microsoft.Authorization/policies/deny/action\"\n| project TimeGenerated, Caller, ResourceGroup, _ResourceId\n| order by TimeGenerated desc"
          size          = 0
          queryType     = 0
          resourceType  = "microsoft.operationalinsights/workspaces"
          visualization = "table"
        }
        name = "policy-denies"
      },
      {
        type = 3
        content = {
          version       = "KqlItem/1.0"
          title         = "SQL failover group changes (last 7d)"
          query         = "AzureActivity\n| where TimeGenerated > ago(7d) and OperationNameValue =~ \"Microsoft.Sql/servers/failoverGroups/failover/action\"\n| project TimeGenerated, Caller, ActivityStatusValue, _ResourceId\n| order by TimeGenerated desc"
          size          = 0
          queryType     = 0
          resourceType  = "microsoft.operationalinsights/workspaces"
          visualization = "table"
        }
        name = "sql-failover"
      }
    ]
    isLocked            = false
    fallbackResourceIds = [lower(local.law_id)]
  })
}
