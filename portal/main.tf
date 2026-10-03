# ── Member portal ────────────────────────────────────────────────────────────
# A member-facing app shaped like the stack a pharmacy cooperative runs: Front
# Door with WAF in front of two regions, Container Apps, API Management for
# partners, Azure SQL with a failover group, Entra External ID for member
# sign-in, a Logic App integration, and Application Insights. It lands on the
# base landing zone: same management group policies (tags, regions, no public
# IPs, phi network rules), same Log Analytics workspace, same ops action group.
#
# Failover runs on two clocks (see docs/portal.md): Front Door moves traffic
# between regions in seconds; the SQL failover group moves the writable
# database independently. Both regions always connect to the failover group
# listener, so the app tier never has to know which database is primary.

resource "random_string" "suffix" {
  length  = 5
  upper   = false
  special = false
}

locals {
  quickstart_image = "mcr.microsoft.com/k8se/quickstart:latest"
  is_quickstart    = var.app_image == local.quickstart_image
  # The quickstart image listens on 80; the portal image runs as non-root on 8080.
  target_port = local.is_quickstart ? 80 : 8080

  law_id              = data.terraform_remote_state.base.outputs.log_analytics_workspace_id
  ops_action_group_id = data.terraform_remote_state.base.outputs.ops_action_group_id
  suffix              = random_string.suffix.result

  # One entry per region. CIDRs come from the portfolio address plan's growth
  # range (10.5 onward), so nothing overlaps the hub or the tier spokes.
  regions = {
    primary = {
      location = var.primary_location
      short    = "cus"
      cidr     = "10.5.0.0/16"
      priority = 1
    }
    secondary = {
      location = var.secondary_location
      short    = "eus2"
      cidr     = "10.6.0.0/16"
      priority = 2
    }
  }

  base_tags = {
    project     = "azure-landing-zone"
    component   = "member-portal"
    owner       = var.owner
    managed_by  = "terraform"
    cost_center = var.cost_center
    environment = "prod"
  }
}

# Edge and shared services: Front Door, WAF, API Management, Logic App,
# Application Insights. No member data lives here.
resource "azurerm_resource_group" "edge" {
  name     = "rg-${var.project}-portal-edge"
  location = var.primary_location
  tags     = merge(local.base_tags, { data_classification = "internal" })
}

# One per region: network, Container Apps environment and app.
resource "azurerm_resource_group" "region" {
  for_each = local.regions

  name     = "rg-${var.project}-portal-${each.value.short}"
  location = each.value.location
  tags     = merge(local.base_tags, { data_classification = "confidential" })
}

# Member data. Tagged phi, so the base policy denies any SQL server, Key Vault,
# storage account, or PostgreSQL server here with public network access.
resource "azurerm_resource_group" "data" {
  name     = "rg-${var.project}-portal-data"
  location = var.primary_location
  tags     = merge(local.base_tags, { data_classification = "phi" })
}
