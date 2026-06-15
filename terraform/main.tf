locals {
  tags = {
    project    = "azure-landing-zone"
    owner      = "jordann6"
    managed_by = "terraform"
  }
}

data "azurerm_client_config" "current" {}
data "azurerm_subscription" "current" {}

# ── Management group hierarchy ────────────────────────────────────────────────
# Four-level tree rooted under the tenant root group.

resource "azurerm_management_group" "root" {
  display_name = "jordann6"
  name         = "mg-jordann6"
}

resource "azurerm_management_group" "platform" {
  display_name               = "Platform"
  name                       = "mg-jordann6-platform"
  parent_management_group_id = azurerm_management_group.root.id
}

resource "azurerm_management_group" "workloads" {
  display_name               = "Workloads"
  name                       = "mg-jordann6-workloads"
  parent_management_group_id = azurerm_management_group.root.id
}

resource "azurerm_management_group" "sandbox" {
  display_name               = "Sandbox"
  name                       = "mg-jordann6-sandbox"
  parent_management_group_id = azurerm_management_group.root.id
}

# Move the subscription into the Workloads management group so the policies
# assigned below take effect on all resources in this subscription.
resource "azurerm_management_group_subscription_association" "workloads" {
  management_group_id = azurerm_management_group.workloads.id
  subscription_id     = data.azurerm_subscription.current.id
}

# ── Policy definitions (scoped to Workloads MG) ───────────────────────────────

resource "azurerm_policy_definition" "require_owner_tag" {
  name                = "require-owner-tag"
  policy_type         = "Custom"
  mode                = "Indexed"
  display_name        = "Require owner tag on resource groups"
  management_group_id = azurerm_management_group.workloads.id

  policy_rule = jsonencode({
    if = {
      allOf = [
        {
          field  = "type"
          equals = "Microsoft.Resources/resourceGroups"
        },
        {
          field  = "tags['owner']"
          exists = "false"
        }
      ]
    }
    then = {
      effect = "Audit"
    }
  })
}

resource "azurerm_policy_definition" "deny_public_ip" {
  name                = "deny-public-ip"
  policy_type         = "Custom"
  mode                = "Indexed"
  display_name        = "Deny public IP creation"
  management_group_id = azurerm_management_group.workloads.id

  policy_rule = jsonencode({
    if = {
      field  = "type"
      equals = "Microsoft.Network/publicIPAddresses"
    }
    then = {
      effect = "Audit"
    }
  })
}

resource "azurerm_policy_definition" "allowed_locations" {
  name                = "allowed-locations"
  policy_type         = "Custom"
  mode                = "Indexed"
  display_name        = "Allowed resource locations"
  management_group_id = azurerm_management_group.workloads.id

  parameters = jsonencode({
    allowedLocations = {
      type = "Array"
      metadata = {
        displayName = "Allowed locations"
        description = "List of allowed Azure regions"
      }
    }
  })

  policy_rule = jsonencode({
    if = {
      not = {
        field = "location"
        in    = "[parameters('allowedLocations')]"
      }
    }
    then = {
      effect = "Audit"
    }
  })
}

# ── Policy assignments ────────────────────────────────────────────────────────

resource "azurerm_management_group_policy_assignment" "require_owner_tag" {
  name                 = "req-owner-tag"
  display_name         = "Require owner tag on resource groups"
  policy_definition_id = azurerm_policy_definition.require_owner_tag.id
  management_group_id  = azurerm_management_group.workloads.id

  depends_on = [azurerm_management_group_subscription_association.workloads]
}

resource "azurerm_management_group_policy_assignment" "deny_public_ip" {
  name                 = "deny-public-ip"
  display_name         = "Deny public IP creation"
  policy_definition_id = azurerm_policy_definition.deny_public_ip.id
  management_group_id  = azurerm_management_group.workloads.id

  depends_on = [azurerm_management_group_subscription_association.workloads]
}

resource "azurerm_management_group_policy_assignment" "allowed_locations" {
  name                 = "allowed-locations"
  display_name         = "Allowed resource locations"
  policy_definition_id = azurerm_policy_definition.allowed_locations.id
  management_group_id  = azurerm_management_group.workloads.id

  parameters = jsonencode({
    allowedLocations = { value = ["eastus", "eastus2", "global"] }
  })

  depends_on = [azurerm_management_group_subscription_association.workloads]
}

# ── Hub networking ────────────────────────────────────────────────────────────
# Hub VNet with pre-sized reserved subnets for Firewall, Gateway, and Bastion.
# The services themselves are not deployed (cost), but the subnets are
# correctly named and sized so they can be activated without re-addressing.

resource "azurerm_resource_group" "hub" {
  name     = "rg-${var.project}-hub"
  location = var.location
  tags     = local.tags
}

resource "azurerm_virtual_network" "hub" {
  name                = "vnet-${var.project}-hub"
  location            = azurerm_resource_group.hub.location
  resource_group_name = azurerm_resource_group.hub.name
  address_space       = ["10.0.0.0/16"]
  tags                = local.tags
}

# /26 — minimum size required by Azure Firewall
resource "azurerm_subnet" "firewall" {
  name                 = "AzureFirewallSubnet"
  resource_group_name  = azurerm_resource_group.hub.name
  virtual_network_name = azurerm_virtual_network.hub.name
  address_prefixes     = ["10.0.0.0/26"]
}

# /27 — minimum size required by VPN / ExpressRoute Gateway
resource "azurerm_subnet" "gateway" {
  name                 = "GatewaySubnet"
  resource_group_name  = azurerm_resource_group.hub.name
  virtual_network_name = azurerm_virtual_network.hub.name
  address_prefixes     = ["10.0.1.0/27"]
}

# /26 — minimum size required by Azure Bastion
resource "azurerm_subnet" "bastion" {
  name                 = "AzureBastionSubnet"
  resource_group_name  = azurerm_resource_group.hub.name
  virtual_network_name = azurerm_virtual_network.hub.name
  address_prefixes     = ["10.0.2.0/26"]
}

resource "azurerm_subnet" "management" {
  name                 = "snet-management"
  resource_group_name  = azurerm_resource_group.hub.name
  virtual_network_name = azurerm_virtual_network.hub.name
  address_prefixes     = ["10.0.3.0/24"]
}

resource "azurerm_network_security_group" "management" {
  name                = "nsg-${var.project}-management"
  location            = azurerm_resource_group.hub.location
  resource_group_name = azurerm_resource_group.hub.name
  tags                = local.tags

  security_rule {
    name                       = "deny-internet-inbound"
    priority                   = 1000
    direction                  = "Inbound"
    access                     = "Deny"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "Internet"
    destination_address_prefix = "*"
  }
}

resource "azurerm_subnet_network_security_group_association" "management" {
  subnet_id                 = azurerm_subnet.management.id
  network_security_group_id = azurerm_network_security_group.management.id
}

# ── Spoke landing zones (vended via reusable module) ─────────────────────────

module "spoke_platform" {
  source = "./modules/landing-zone"

  name                    = "platform"
  project                 = var.project
  location                = var.location
  address_space           = ["10.1.0.0/16"]
  workload_subnet_prefix  = "10.1.0.0/24"
  hub_vnet_id             = azurerm_virtual_network.hub.id
  hub_vnet_name           = azurerm_virtual_network.hub.name
  hub_resource_group_name = azurerm_resource_group.hub.name
  tags                    = local.tags
}

module "spoke_sandbox" {
  source = "./modules/landing-zone"

  name                    = "sandbox"
  project                 = var.project
  location                = var.location
  address_space           = ["10.2.0.0/16"]
  workload_subnet_prefix  = "10.2.0.0/24"
  hub_vnet_id             = azurerm_virtual_network.hub.id
  hub_vnet_name           = azurerm_virtual_network.hub.name
  hub_resource_group_name = azurerm_resource_group.hub.name
  tags                    = local.tags
}
