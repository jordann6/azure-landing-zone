# ── Azure Bastion (gated) ────────────────────────────────────────────────────
# The only admin path into the estate: browser-based SSH/RDP through Bastion, no
# public IP on any VM and no public SSH/RDP. Satisfies the "no public admin path"
# pillar. Gated on enable_bastion (default true); Bastion Basic bills ~$0.19/hr.

locals {
  bastion_count = var.enable_bastion ? 1 : 0
}

resource "azurerm_public_ip" "bastion" {
  count               = local.bastion_count
  name                = "pip-${var.project}-bastion"
  location            = azurerm_resource_group.hub.location
  resource_group_name = azurerm_resource_group.hub.name
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = local.tags
}

resource "azurerm_bastion_host" "hub" {
  count               = local.bastion_count
  name                = "bas-${var.project}-hub"
  location            = azurerm_resource_group.hub.location
  resource_group_name = azurerm_resource_group.hub.name
  sku                 = "Basic"
  tags                = local.tags

  ip_configuration {
    name                 = "bastion-ipconfig"
    subnet_id            = azurerm_subnet.bastion.id
    public_ip_address_id = azurerm_public_ip.bastion[0].id
  }
}
