# ── Front Door Premium + WAF ────────────────────────────────────────────────
# The single public entry point. Premium is required for Private Link origins
# and for the managed WAF rule sets. Front Door health-probes /health in each
# region every 30 seconds and sends traffic to the primary (priority 1) while
# it is healthy, the secondary (priority 2) when it is not. That is the fast
# failover clock.

resource "azurerm_cdn_frontdoor_profile" "portal" {
  name                     = "afd-${var.project}-portal-${local.suffix}"
  resource_group_name      = azurerm_resource_group.edge.name
  sku_name                 = "Premium_AzureFrontDoor"
  response_timeout_seconds = 60
  tags                     = azurerm_resource_group.edge.tags
}

resource "azurerm_cdn_frontdoor_endpoint" "portal" {
  name                     = "portal-${local.suffix}"
  cdn_frontdoor_profile_id = azurerm_cdn_frontdoor_profile.portal.id
  tags                     = azurerm_resource_group.edge.tags
}

resource "azurerm_cdn_frontdoor_origin_group" "portal" {
  name                     = "og-portal"
  cdn_frontdoor_profile_id = azurerm_cdn_frontdoor_profile.portal.id
  session_affinity_enabled = false

  load_balancing {
    sample_size                        = 4
    successful_samples_required        = 3
    additional_latency_in_milliseconds = 50
  }

  health_probe {
    path                = "/health"
    protocol            = "Https"
    request_type        = "GET"
    interval_in_seconds = 30
  }
}

# Origins over Private Link to each internal Container Apps environment.
# azapi because azurerm 3.x only accepts blob, web, and sites as Private Link
# targets; "managedEnvironments" is the Container Apps sub-resource. Front
# Door creates a managed private endpoint per origin, which must be approved
# on the environment side: scripts/portal-approve-private-links.sh.
resource "azapi_resource" "origin" {
  for_each = local.regions

  type      = "Microsoft.Cdn/profiles/originGroups/origins@2024-02-01"
  name      = "origin-${each.value.short}"
  parent_id = azurerm_cdn_frontdoor_origin_group.portal.id

  body = {
    properties = {
      hostName                    = azurerm_container_app.portal[each.key].ingress[0].fqdn
      originHostHeader            = azurerm_container_app.portal[each.key].ingress[0].fqdn
      httpPort                    = 80
      httpsPort                   = 443
      priority                    = each.value.priority
      weight                      = 1000
      enabledState                = "Enabled"
      enforceCertificateNameCheck = true
      sharedPrivateLinkResource = {
        privateLink = {
          id = azapi_resource.aca_env[each.key].id
        }
        groupId             = "managedEnvironments"
        privateLinkLocation = each.value.location
        requestMessage      = "Front Door to ${each.value.short} member portal"
      }
    }
  }
}

resource "azurerm_cdn_frontdoor_route" "portal" {
  name                          = "route-portal"
  cdn_frontdoor_endpoint_id     = azurerm_cdn_frontdoor_endpoint.portal.id
  cdn_frontdoor_origin_group_id = azurerm_cdn_frontdoor_origin_group.portal.id
  cdn_frontdoor_origin_ids      = [for o in azapi_resource.origin : o.id]
  supported_protocols           = ["Http", "Https"]
  patterns_to_match             = ["/*"]
  forwarding_protocol           = "HttpsOnly"
  https_redirect_enabled        = true
  link_to_default_domain        = true
}

# WAF: Microsoft's managed Default Rule Set (OWASP-style protections) and Bot
# Manager, plus a per-IP rate limit. Prevention mode blocks; Detection logs.
resource "azurerm_cdn_frontdoor_firewall_policy" "portal" {
  name                = "waf${var.project}portal${local.suffix}"
  resource_group_name = azurerm_resource_group.edge.name
  sku_name            = "Premium_AzureFrontDoor"
  enabled             = true
  mode                = var.waf_mode
  tags                = azurerm_resource_group.edge.tags

  custom_rule {
    name                           = "RateLimitPerIp"
    type                           = "RateLimitRule"
    priority                       = 100
    enabled                        = true
    action                         = "Block"
    rate_limit_duration_in_minutes = 1
    rate_limit_threshold           = 300

    # Matches every client (no address equals 255.255.255.255/32), so the
    # limit applies per source IP across the whole site.
    match_condition {
      match_variable     = "RemoteAddr"
      operator           = "IPMatch"
      negation_condition = true
      match_values       = ["255.255.255.255/32"]
    }
  }

  managed_rule {
    type    = "Microsoft_DefaultRuleSet"
    version = "2.1"
    action  = "Block"
  }

  managed_rule {
    type    = "Microsoft_BotManagerRuleSet"
    version = "1.1"
    action  = "Block"
  }
}

resource "azurerm_cdn_frontdoor_security_policy" "portal" {
  name                     = "secpol-portal"
  cdn_frontdoor_profile_id = azurerm_cdn_frontdoor_profile.portal.id

  security_policies {
    firewall {
      cdn_frontdoor_firewall_policy_id = azurerm_cdn_frontdoor_firewall_policy.portal.id

      association {
        domain {
          cdn_frontdoor_domain_id = azurerm_cdn_frontdoor_endpoint.portal.id
        }
        patterns_to_match = ["/*"]
      }
    }
  }
}

resource "azurerm_monitor_diagnostic_setting" "frontdoor" {
  name                       = "diag-frontdoor"
  target_resource_id         = azurerm_cdn_frontdoor_profile.portal.id
  log_analytics_workspace_id = local.law_id

  enabled_log { category = "FrontDoorAccessLog" }
  enabled_log { category = "FrontDoorHealthProbeLog" }
  enabled_log { category = "FrontDoorWebApplicationFirewallLog" }

  metric {
    category = "AllMetrics"
    enabled  = true
  }
}
