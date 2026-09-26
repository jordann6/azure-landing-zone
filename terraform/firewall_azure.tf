# ── Azure Firewall hub egress inspection (gated) ─────────────────────────────
# The managed-service egress chokepoint: every spoke's default route points at
# the firewall's private IP, so all north-south traffic is inspected in the hub.
# This is the primary inspection path; the FortiGate NVA in firewall.tf is the
# opt-in third-party alternative. The two are mutually exclusive (both force
# 0.0.0.0/0 through a different next hop on the same spoke subnets).
#
# Gated on enable_firewall (default true). Azure Firewall bills ~$1.25/hr plus
# data, so a gitignored terraform.tfvars sets enable_firewall = false for a
# cheap governance-only apply.

locals {
  fw_azure_count = var.enable_firewall ? 1 : 0
}

resource "azurerm_public_ip" "firewall" {
  count               = local.fw_azure_count
  name                = "pip-${var.project}-fw"
  location            = azurerm_resource_group.hub.location
  resource_group_name = azurerm_resource_group.hub.name
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = local.tags
}

resource "azurerm_firewall_policy" "hub" {
  count                    = local.fw_azure_count
  name                     = "afwp-${var.project}-hub"
  location                 = azurerm_resource_group.hub.location
  resource_group_name      = azurerm_resource_group.hub.name
  sku                      = "Standard"
  threat_intelligence_mode = "Deny"
  tags                     = local.tags

  # checkov:skip=CKV_AZURE_220:IDPS is a Premium-tier feature. This landing zone
  # runs Azure Firewall Standard to stay inside the demo cost ceiling; IDPS mode
  # is documented as the Premium upgrade path in the README.
}

# A minimal egress allow-list so the demo can prove traffic is steered through
# the firewall (not that the firewall is wide open). Everything else is denied
# by the firewall's implicit default.
resource "azurerm_firewall_policy_rule_collection_group" "egress" {
  count              = local.fw_azure_count
  name               = "rcg-egress"
  firewall_policy_id = azurerm_firewall_policy.hub[0].id
  priority           = 500

  application_rule_collection {
    name     = "allow-baseline-egress"
    priority = 500
    action   = "Allow"

    rule {
      name = "allow-https"
      protocols {
        type = "Https"
        port = 443
      }
      source_addresses  = ["10.0.0.0/8"]
      destination_fqdns = ["*.ubuntu.com", "*.azure.com", "*.microsoft.com"]
    }
  }
}

resource "azurerm_firewall" "hub" {
  count               = local.fw_azure_count
  name                = "afw-${var.project}-hub"
  location            = azurerm_resource_group.hub.location
  resource_group_name = azurerm_resource_group.hub.name
  sku_name            = "AZFW_VNet"
  sku_tier            = "Standard"
  firewall_policy_id  = azurerm_firewall_policy.hub[0].id
  tags                = local.tags

  # checkov:skip=CKV_AZURE_216:Threat-intel mode is set to Deny on the linked
  # firewall policy (threat_intelligence_mode above), not the classic
  # threat_intel_mode argument, which cannot coexist with firewall_policy_id.

  ip_configuration {
    name                 = "fw-ipconfig"
    subnet_id            = azurerm_subnet.firewall.id
    public_ip_address_id = azurerm_public_ip.firewall[0].id
  }

  lifecycle {
    precondition {
      condition     = !(var.enable_firewall && var.enable_fortigate)
      error_message = "enable_firewall and enable_fortigate are mutually exclusive: both force spoke egress through a different next hop on the same subnets. Enable one."
    }
  }
}

# Force every spoke workload subnet's default route through the firewall.
resource "azurerm_route_table" "spoke_egress" {
  count               = local.fw_azure_count
  name                = "rt-${var.project}-spoke-egress"
  location            = azurerm_resource_group.hub.location
  resource_group_name = azurerm_resource_group.hub.name
  tags                = local.tags

  route {
    name                   = "default-via-firewall"
    address_prefix         = "0.0.0.0/0"
    next_hop_type          = "VirtualAppliance"
    next_hop_in_ip_address = azurerm_firewall.hub[0].ip_configuration[0].private_ip_address
  }
}

resource "azurerm_subnet_route_table_association" "spoke_egress" {
  for_each = local.fw_azure_count == 1 ? local.spoke_workload_subnet_ids : {}

  subnet_id      = each.value
  route_table_id = azurerm_route_table.spoke_egress[0].id
}
