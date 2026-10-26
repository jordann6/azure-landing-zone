# Proof root for the gated Azure CI path. CI applies and destroys this root
# through platform-guardrails tf-apply.yml / tf-destroy.yml, end to end on
# federated identities, with no long-lived credential.
#
# It holds only free resources (an isolated VNet, a subnet and an NSG) inside the
# operator-owned rg-alz-ci. Governance, workload and compute stay operator-applied.

data "azurerm_resource_group" "ci" {
  name = var.resource_group_name
}

locals {
  tags = {
    project             = "azure-landing-zone"
    environment         = "ci"
    owner               = "jordann6"
    cost_center         = "platform"
    data_classification = "internal"
    managed_by          = "terraform"
  }
}

resource "azurerm_virtual_network" "ci" {
  name                = "vnet-alz-ci"
  location            = data.azurerm_resource_group.ci.location
  resource_group_name = data.azurerm_resource_group.ci.name
  address_space       = var.address_space
  tags                = local.tags
}

resource "azurerm_subnet" "ci" {
  name                            = "snet-ci"
  resource_group_name             = data.azurerm_resource_group.ci.name
  virtual_network_name            = azurerm_virtual_network.ci.name
  address_prefixes                = [cidrsubnet(var.address_space[0], 2, 0)]
  default_outbound_access_enabled = false
}

# Explicit deny-all inbound below the default rules, so the intent is in code
# rather than implied by Azure's defaults.
resource "azurerm_network_security_group" "ci" {
  name                = "nsg-alz-ci"
  location            = data.azurerm_resource_group.ci.location
  resource_group_name = data.azurerm_resource_group.ci.name
  tags                = local.tags

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

resource "azurerm_subnet_network_security_group_association" "ci" {
  subnet_id                 = azurerm_subnet.ci.id
  network_security_group_id = azurerm_network_security_group.ci.id
}
