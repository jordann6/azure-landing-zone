# ── Hub networking ────────────────────────────────────────────────────────────
# Hub VNet with pre-sized subnets for Firewall, Gateway, Bastion, and a
# management subnet. The Firewall/Bastion services (firewall_azure.tf,
# bastion.tf) are gated so the hub still applies cheaply as a governance demo.

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
  # checkov:skip=CKV2_AZURE_31:AzureBastionSubnet is managed by the Bastion
  # service, which requires its own fixed rule set; attaching a custom NSG
  # without those exact rules breaks Bastion, so it is left to the service.
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

# Dedicated subnet for private endpoints (10.0.4-5 are reserved for the FortiGate
# NVA when that opt-in path is used, so private link lands at 10.0.6.0/24).
resource "azurerm_subnet" "privatelink" {
  # checkov:skip=CKV2_AZURE_31:Private endpoint NICs bypass subnet NSGs by design
  # (network policies are disabled on this subnet), so an NSG here would have no
  # effect on private-endpoint traffic.
  name                              = "snet-privatelink"
  resource_group_name               = azurerm_resource_group.hub.name
  virtual_network_name              = azurerm_virtual_network.hub.name
  address_prefixes                  = ["10.0.6.0/24"]
  private_endpoint_network_policies = "Disabled"
}

# ── Spoke landing zones (vended via the reusable module) ─────────────────────
# One spoke per tier, on the portfolio's shared address plan:
#   dev 10.1/16, test 10.2/16, prod 10.3/16, sandbox 10.4/16.

module "spoke_dev" {
  source = "./modules/landing-zone"

  name                    = "dev"
  project                 = var.project
  location                = var.location
  address_space           = ["10.1.0.0/16"]
  workload_subnet_prefix  = "10.1.0.0/24"
  hub_vnet_id             = azurerm_virtual_network.hub.id
  hub_vnet_name           = azurerm_virtual_network.hub.name
  hub_resource_group_name = azurerm_resource_group.hub.name
  tags                    = merge(local.tags, { environment = "dev" })
}

module "spoke_test" {
  source = "./modules/landing-zone"

  name                    = "test"
  project                 = var.project
  location                = var.location
  address_space           = ["10.2.0.0/16"]
  workload_subnet_prefix  = "10.2.0.0/24"
  hub_vnet_id             = azurerm_virtual_network.hub.id
  hub_vnet_name           = azurerm_virtual_network.hub.name
  hub_resource_group_name = azurerm_resource_group.hub.name
  tags                    = merge(local.tags, { environment = "test" })
}

module "spoke_prod" {
  source = "./modules/landing-zone"

  name                    = "prod"
  project                 = var.project
  location                = var.location
  address_space           = ["10.3.0.0/16"]
  workload_subnet_prefix  = "10.3.0.0/24"
  hub_vnet_id             = azurerm_virtual_network.hub.id
  hub_vnet_name           = azurerm_virtual_network.hub.name
  hub_resource_group_name = azurerm_resource_group.hub.name
  tags                    = merge(local.tags, { environment = "prod" })
}

module "spoke_sandbox" {
  source = "./modules/landing-zone"

  name                    = "sandbox"
  project                 = var.project
  location                = var.location
  address_space           = ["10.4.0.0/16"]
  workload_subnet_prefix  = "10.4.0.0/24"
  hub_vnet_id             = azurerm_virtual_network.hub.id
  hub_vnet_name           = azurerm_virtual_network.hub.name
  hub_resource_group_name = azurerm_resource_group.hub.name
  tags                    = merge(local.tags, { environment = "sandbox" })
}

# All spoke workload subnets, keyed for route-table / UDR association.
locals {
  spoke_workload_subnet_ids = {
    dev     = module.spoke_dev.workload_subnet_id
    test    = module.spoke_test.workload_subnet_id
    prod    = module.spoke_prod.workload_subnet_id
    sandbox = module.spoke_sandbox.workload_subnet_id
  }
}
