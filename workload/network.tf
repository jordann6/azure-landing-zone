# Prod workload VNet (10.3.0.0/16). Fully private: no public IP, no NAT gateway.
# All egress leaves through the hub Azure Firewall via a user-defined route, so
# this VNet inherits the centralized inspection and has no independent path to the
# internet. Mirrors aws-landing-zone/workload/vpc.tf (prod VPC, no IGW/NAT, all
# egress through the TGW to the hub firewall).

resource "azurerm_resource_group" "prod" {
  name     = coalesce(var.resource_group_name, "rg-${var.project}-prod-workload")
  location = var.location
  tags     = local.tags
}

resource "azurerm_virtual_network" "prod" {
  name                = "vnet-${var.project}-prod"
  location            = azurerm_resource_group.prod.location
  resource_group_name = azurerm_resource_group.prod.name
  address_space       = [var.prod_cidr]
  tags                = local.tags
}

resource "azurerm_subnet" "aks" {
  # checkov:skip=CKV2_AZURE_31:AKS manages the node subnet's effective NSG (an outer NSG must match the AKS-required rules or it breaks the cluster), so it is left to the service, as the base LZ leaves AzureBastionSubnet.
  name                 = "snet-aks"
  resource_group_name  = azurerm_resource_group.prod.name
  virtual_network_name = azurerm_virtual_network.prod.name
  address_prefixes     = [var.aks_subnet_prefix]
}

# Delegated to the PostgreSQL flexible server (VNet-injected, private).
resource "azurerm_subnet" "data" {
  name                 = "snet-data"
  resource_group_name  = azurerm_resource_group.prod.name
  virtual_network_name = azurerm_virtual_network.prod.name
  address_prefixes     = [var.data_subnet_prefix]

  # PostgreSQL flexible server adds the Microsoft.Storage service endpoint to its
  # delegated subnet (for backup storage); declared here so Terraform matches the
  # platform instead of fighting it on every apply.
  service_endpoints = ["Microsoft.Storage"]

  delegation {
    name = "pg-flexible"
    service_delegation {
      name    = "Microsoft.DBforPostgreSQL/flexibleServers"
      actions = ["Microsoft.Network/virtualNetworks/subnets/join/action"]
    }
  }
}

resource "azurerm_subnet" "app" {
  name                 = "snet-app"
  resource_group_name  = azurerm_resource_group.prod.name
  virtual_network_name = azurerm_virtual_network.prod.name
  address_prefixes     = [var.app_subnet_prefix]
}

resource "azurerm_subnet" "pe" {
  # checkov:skip=CKV2_AZURE_31:Private-endpoint NICs bypass subnet NSGs by design (network policies are disabled here), so an NSG would have no effect, mirroring the base LZ privatelink subnet.
  name                              = "snet-privatelink"
  resource_group_name               = azurerm_resource_group.prod.name
  virtual_network_name              = azurerm_virtual_network.prod.name
  address_prefixes                  = [var.pe_subnet_prefix]
  private_endpoint_network_policies = "Disabled"
}

# API Server VNet Integration subnet: the private control plane is projected into
# this delegated subnet so it can reach the etcd CMK over the Key Vault private
# endpoint. Azure requires VNet integration when the KMS key_vault_network_access
# is Private; the vault itself stays default-Deny (no public exposure).
resource "azurerm_subnet" "apiserver" {
  # checkov:skip=CKV2_AZURE_31:The API-server delegated subnet is managed by AKS (its effective rules must match the service requirements), so it is left to the service like the node subnet.
  name                 = "snet-apiserver"
  resource_group_name  = azurerm_resource_group.prod.name
  virtual_network_name = azurerm_virtual_network.prod.name
  address_prefixes     = [var.apiserver_subnet_prefix]

  delegation {
    name = "aks-apiserver"
    service_delegation {
      name    = "Microsoft.ContainerService/managedClusters"
      actions = ["Microsoft.Network/virtualNetworks/subnets/join/action"]
    }
  }
}

# ── Egress through the hub firewall (mirrors the AWS private route table -> TGW) ─
# 0.0.0.0/0 to the firewall private IP published by the base landing zone. The AKS
# subnet carries this route so outbound_type=userDefinedRouting has a next hop and
# the cluster has no internet path except through the inspected hub.
resource "azurerm_route_table" "egress" {
  name                = "rt-${var.project}-prod-egress"
  location            = azurerm_resource_group.prod.location
  resource_group_name = azurerm_resource_group.prod.name
  tags                = local.tags

  lifecycle {
    precondition {
      condition     = local.firewall_private_ip != null
      error_message = "The base landing zone must be deployed with enable_firewall = true (firewall_private_ip output is null). The prod workload routes egress through the hub firewall."
    }
  }

  route {
    name                   = "default-via-firewall"
    address_prefix         = "0.0.0.0/0"
    next_hop_type          = "VirtualAppliance"
    next_hop_in_ip_address = local.firewall_private_ip
  }
}

resource "azurerm_subnet_route_table_association" "aks" {
  subnet_id      = azurerm_subnet.aks.id
  route_table_id = azurerm_route_table.egress.id
}

resource "azurerm_subnet_route_table_association" "app" {
  subnet_id      = azurerm_subnet.app.id
  route_table_id = azurerm_route_table.egress.id
}

# ── Peering to the hub (both directions, single subscription) ─────────────────
resource "azurerm_virtual_network_peering" "prod_to_hub" {
  name                         = "peer-prod-to-hub"
  resource_group_name          = azurerm_resource_group.prod.name
  virtual_network_name         = azurerm_virtual_network.prod.name
  remote_virtual_network_id    = local.hub_vnet_id
  allow_virtual_network_access = true
  allow_forwarded_traffic      = true
  use_remote_gateways          = false
}

resource "azurerm_virtual_network_peering" "hub_to_prod" {
  name                         = "peer-hub-to-prod"
  resource_group_name          = local.hub_rg_name
  virtual_network_name         = local.hub_vnet_name
  remote_virtual_network_id    = azurerm_virtual_network.prod.id
  allow_virtual_network_access = true
  allow_forwarded_traffic      = true
  use_remote_gateways          = false
}
