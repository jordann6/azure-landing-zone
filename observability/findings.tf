# ── Security findings routing ────────────────────────────────────────────────
# The AWS zone routes HIGH and CRITICAL GuardDuty and Security Hub findings to one
# topic; the GCP zone streams SCC findings to Pub/Sub. The Azure equivalent is
# Defender for Cloud continuous export into the same workspace everything else
# lands in, plus one alert on HIGH severity so a finding pages the owner instead
# of waiting to be looked for.
#
# Honest limit: the free foundational CSPM tier produces recommendations, not
# threat alerts. SecurityAlert stays empty until a paid plan is on
# (enable_defender_standard in the base root), so the HIGH alert is armed but quiet
# by default. The recommendation export works on the free tier.

resource "azurerm_security_center_automation" "export" {
  count = var.enable_findings_export ? 1 : 0

  name                = "export-${var.project}-defender"
  location            = var.location
  resource_group_name = local.logging_rg
  scopes              = [data.azurerm_subscription.current.id]
  tags                = local.tags

  source {
    event_source = "Alerts"
    rule_set {
      rule {
        expected_value = "High"
        operator       = "Equals"
        property_path  = "properties.metadata.severity"
        property_type  = "String"
      }
    }
  }

  source {
    event_source = "Assessments"
    rule_set {
      rule {
        expected_value = "High"
        operator       = "Equals"
        property_path  = "properties.metadata.severity"
        property_type  = "String"
      }
    }
  }

  action {
    type        = "Workspace"
    resource_id = local.law_id
  }

  lifecycle {
    precondition {
      condition     = local.base_ready
      error_message = "The base landing zone (terraform/) must be deployed first: the central workspace is missing from its state."
    }
  }
}

# Log alert: a HIGH Defender alert reached the workspace. skip_query_validation
# because SecurityAlert does not exist in a workspace until the first alert.
resource "azurerm_monitor_scheduled_query_rules_alert_v2" "defender_high" {
  count = var.enable_findings_export ? 1 : 0

  name                  = "alert-${var.project}-defender-high"
  resource_group_name   = local.logging_rg
  location              = var.location
  scopes                = [local.law_id]
  description           = "Defender for Cloud raised a HIGH severity alert."
  severity              = 1
  evaluation_frequency  = "PT15M"
  window_duration       = "PT15M"
  skip_query_validation = true
  tags                  = local.tags

  criteria {
    query                   = <<-KQL
      SecurityAlert
      | where AlertSeverity == "High"
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
      error_message = "The base landing zone (terraform/) must be deployed first: ops_action_group_id is missing from its state."
    }
  }
}
