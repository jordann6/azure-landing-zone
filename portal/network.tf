# ── Regional networks ────────────────────────────────────────────────────────
# Each region gets a VNet with two subnets, the layout Microsoft documents for
# Front Door Premium + Private Link + Container Apps:
#   snet-aca /23  delegated to Microsoft.App/environments (room for replicas)
#   snet-pe  /24  non-delegated, for private endpoints (SQL)
# The two VNets are globally peered so either region's app can reach whichever
# SQL server is currently primary, over private IPs.

resource "azurerm_virtual_network" "region" {
  for_each = local.regions

  name                = "vnet-${var.project}-portal-${each.value.short}"
  location            = each.value.location
  resource_group_name = azurerm_resource_group.region[each.key].name
  address_space       = [each.value.cidr]
  tags                = azurerm_resource_group.region[each.key].tags
}

resource "azurerm_subnet" "aca" {
  # checkov:skip=CKV2_AZURE_31:The Container Apps infrastructure subnet is managed by the platform (it programs the environment's own rules); the environment is internal with public network access disabled, and the only inbound path is Front Door over Private Link.
  for_each = local.regions

  name                 = "snet-aca"
  resource_group_name  = azurerm_resource_group.region[each.key].name
  virtual_network_name = azurerm_virtual_network.region[each.key].name
  address_prefixes     = [cidrsubnet(each.value.cidr, 7, 0)]

  delegation {
    name = "aca"
    service_delegation {
      name    = "Microsoft.App/environments"
      actions = ["Microsoft.Network/virtualNetworks/subnets/join/action"]
    }
  }
}

resource "azurerm_subnet" "pe" {
  # checkov:skip=CKV2_AZURE_31:Private endpoint NICs bypass subnet NSGs (network policies disabled), matching the base landing zone's privatelink subnet.
  for_each = local.regions

  name                              = "snet-pe"
  resource_group_name               = azurerm_resource_group.region[each.key].name
  virtual_network_name              = azurerm_virtual_network.region[each.key].name
  address_prefixes                  = [cidrsubnet(each.value.cidr, 8, 2)]
  private_endpoint_network_policies = "Disabled"
}

resource "azurerm_virtual_network_peering" "primary_to_secondary" {
  name                         = "peer-${local.regions.primary.short}-to-${local.regions.secondary.short}"
  resource_group_name          = azurerm_resource_group.region["primary"].name
  virtual_network_name         = azurerm_virtual_network.region["primary"].name
  remote_virtual_network_id    = azurerm_virtual_network.region["secondary"].id
  allow_virtual_network_access = true
}

resource "azurerm_virtual_network_peering" "secondary_to_primary" {
  name                         = "peer-${local.regions.secondary.short}-to-${local.regions.primary.short}"
  resource_group_name          = azurerm_resource_group.region["secondary"].name
  virtual_network_name         = azurerm_virtual_network.region["secondary"].name
  remote_virtual_network_id    = azurerm_virtual_network.region["primary"].id
  allow_virtual_network_access = true
}
