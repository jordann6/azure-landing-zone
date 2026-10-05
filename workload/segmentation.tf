# Data-tier segmentation. Only the app tier (and the AKS node subnet) reaches the
# database subnet, on the PostgreSQL port. Everything else is denied at the subnet
# edge. Mirrors aws-landing-zone/workload/segmentation.tf (app/db security groups
# plus the data-subnet NACL). Cross-environment isolation is enforced above this by
# the spoke VNets having no peering to each other and the hub not routing spoke to
# spoke.

locals {
  db_port = "5432"
}

resource "azurerm_network_security_group" "app" {
  name                = "nsg-${var.project}-prod-app"
  location            = azurerm_resource_group.prod.location
  resource_group_name = azurerm_resource_group.prod.name
  tags                = local.tags

  security_rule {
    name                       = "deny-internet-inbound"
    priority                   = 4000
    direction                  = "Inbound"
    access                     = "Deny"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "Internet"
    destination_address_prefix = "*"
  }
}

resource "azurerm_subnet_network_security_group_association" "app" {
  subnet_id                 = azurerm_subnet.app.id
  network_security_group_id = azurerm_network_security_group.app.id
}

resource "azurerm_network_security_group" "data" {
  name                = "nsg-${var.project}-prod-data"
  location            = azurerm_resource_group.prod.location
  resource_group_name = azurerm_resource_group.prod.name
  tags                = local.tags

  # PostgreSQL reachable only from the app and AKS node subnets, on the DB port.
  security_rule {
    name                       = "allow-postgres-from-app-and-aks"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = local.db_port
    source_address_prefixes    = [var.app_subnet_prefix, var.aks_subnet_prefix]
    destination_address_prefix = var.data_subnet_prefix
  }

  # Zone-redundant HA replicates between the primary and standby within this
  # delegated subnet (the standby reaches the primary on the DB port), so intra-
  # subnet DB traffic must be permitted above the catch-all deny. Outbound is
  # already allowed by the default AllowVnetOutBound rule.
  security_rule {
    name                       = "allow-postgres-ha-replication"
    priority                   = 110
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = local.db_port
    source_address_prefix      = var.data_subnet_prefix
    destination_address_prefix = var.data_subnet_prefix
  }

  security_rule {
    name                       = "deny-all-inbound"
    priority                   = 4096
    direction                  = "Inbound"
    access                     = "Deny"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }
}

resource "azurerm_subnet_network_security_group_association" "data" {
  subnet_id                 = azurerm_subnet.data.id
  network_security_group_id = azurerm_network_security_group.data.id
}
