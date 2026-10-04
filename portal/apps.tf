# ── Container Apps: one internal environment and app per region ─────────────
# The environment is a workload-profiles environment injected into snet-aca
# with an internal VIP and public network access disabled, so it has no public
# IP (the base deny-public-IP policy holds) and no internet ingress at all. The
# only way in is Front Door Premium over Private Link (frontdoor.tf).
#
# azapi because azurerm 3.x has no publicNetworkAccess on the environment.
# App Service would be the more familiar target; this subscription has zero
# App Service VM quota, and Container Apps does not draw on that quota.

resource "azapi_resource" "aca_env" {
  for_each = local.regions

  type      = "Microsoft.App/managedEnvironments@2024-10-02-preview"
  name      = "cae-${var.project}-portal-${each.value.short}"
  parent_id = azurerm_resource_group.region[each.key].id
  location  = each.value.location
  tags      = azurerm_resource_group.region[each.key].tags

  body = {
    properties = {
      # Logs go out through diagnostic settings (below), so no workspace
      # shared key is ever handed to the environment.
      appLogsConfiguration = {
        destination = "azure-monitor"
      }
      vnetConfiguration = {
        infrastructureSubnetId = azurerm_subnet.aca[each.key].id
        internal               = true
      }
      workloadProfiles = [
        {
          name                = "Consumption"
          workloadProfileType = "Consumption"
        }
      ]
      # Named so the base tag policies can exclude exactly this platform-managed
      # RG (var.platform_managed_resource_groups in terraform/).
      infrastructureResourceGroup = "rg-${var.project}-portal-${each.value.short}-aca-infra"
      publicNetworkAccess         = "Disabled"
      zoneRedundant               = false
    }
  }

  response_export_values = ["properties.defaultDomain", "properties.staticIp"]
}

resource "azurerm_monitor_diagnostic_setting" "aca_env" {
  for_each = local.regions

  name                       = "diag-aca-env"
  target_resource_id         = azapi_resource.aca_env[each.key].id
  log_analytics_workspace_id = local.law_id

  enabled_log { category_group = "allLogs" }

  metric {
    category = "AllMetrics"
    enabled  = true
  }
}

resource "azurerm_container_app" "portal" {
  for_each = local.regions

  name                         = "ca-${var.project}-portal-${each.value.short}"
  resource_group_name          = azurerm_resource_group.region[each.key].name
  container_app_environment_id = azapi_resource.aca_env[each.key].id
  revision_mode                = "Single"
  workload_profile_name        = "Consumption"
  tags                         = azurerm_resource_group.region[each.key].tags

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.app.id]
  }

  registry {
    server   = azurerm_container_registry.portal.login_server
    identity = azurerm_user_assigned_identity.app.id
  }

  # Stored as a Container Apps secret rather than a plain env var.
  secret {
    name  = "appinsights-connection-string"
    value = azurerm_application_insights.portal.connection_string
  }

  ingress {
    # external_enabled = reachable from outside the environment, which for an
    # internal environment with public access disabled means the VNet and the
    # Front Door private endpoint only.
    external_enabled = true
    target_port      = local.target_port
    transport        = "auto"

    traffic_weight {
      latest_revision = true
      percentage      = 100
    }
  }

  template {
    min_replicas = 1
    max_replicas = 3

    container {
      name   = "portal"
      image  = var.app_image
      cpu    = 0.5
      memory = "1Gi"

      env {
        name  = "REGION"
        value = each.value.location
      }
      env {
        name  = "SQL_SERVER"
        value = "${azurerm_mssql_failover_group.portal.name}.database.windows.net"
      }
      env {
        name  = "SQL_DATABASE"
        value = azurerm_mssql_database.portal.name
      }
      env {
        name  = "AZURE_CLIENT_ID"
        value = azurerm_user_assigned_identity.app.client_id
      }
      env {
        name  = "FRONT_DOOR_ID"
        value = azurerm_cdn_frontdoor_profile.portal.resource_guid
      }
      env {
        name  = "EXTERNAL_ID_TENANT_ID"
        value = local.external_id_tenant_id
      }
      env {
        name  = "EXTERNAL_ID_SUBDOMAIN"
        value = local.external_id_subdomain
      }
      env {
        name  = "EXTERNAL_ID_CLIENT_ID"
        value = var.external_id_client_id
      }
      env {
        name        = "APPLICATIONINSIGHTS_CONNECTION_STRING"
        secret_name = "appinsights-connection-string"
      }

      # Probes hit /livez, which needs no database and no Front Door header.
      # The quickstart image has no /livez, so probes are added only once the
      # real portal image is deployed.
      dynamic "liveness_probe" {
        for_each = local.is_quickstart ? [] : [1]
        content {
          transport = "HTTP"
          port      = local.target_port
          path      = "/livez"
        }
      }
      dynamic "readiness_probe" {
        for_each = local.is_quickstart ? [] : [1]
        content {
          transport = "HTTP"
          port      = local.target_port
          path      = "/livez"
        }
      }
    }
  }

  depends_on = [azurerm_role_assignment.app_acr_pull]
}
