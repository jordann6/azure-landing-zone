# ── Private endpoints + private DNS (gated) ──────────────────────────────────
# Private DNS zones for Key Vault and Blob, linked to the hub VNet, plus a
# private endpoint that pulls the Key Vault onto the hub's private-link subnet so
# it resolves to a private IP. Gated on enable_private_endpoints (default true).

locals {
  pe_count = var.enable_private_endpoints ? 1 : 0

  private_dns_zones = {
    vault = "privatelink.vaultcore.azure.net"
    blob  = "privatelink.blob.core.windows.net"
  }
}

resource "azurerm_private_dns_zone" "zones" {
  for_each = local.pe_count == 1 ? local.private_dns_zones : {}

  name                = each.value
  resource_group_name = azurerm_resource_group.hub.name
  tags                = local.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "hub" {
  for_each = local.pe_count == 1 ? local.private_dns_zones : {}

  name                  = "link-${each.key}-hub"
  resource_group_name   = azurerm_resource_group.hub.name
  private_dns_zone_name = azurerm_private_dns_zone.zones[each.key].name
  virtual_network_id    = azurerm_virtual_network.hub.id
  registration_enabled  = false
  tags                  = local.tags
}

resource "azurerm_private_endpoint" "keyvault" {
  count               = local.pe_count
  name                = "pe-${var.project}-kv"
  location            = azurerm_resource_group.hub.location
  resource_group_name = azurerm_resource_group.hub.name
  subnet_id           = azurerm_subnet.privatelink.id
  tags                = local.tags

  private_service_connection {
    name                           = "psc-${var.project}-kv"
    private_connection_resource_id = azurerm_key_vault.cmk.id
    is_manual_connection           = false
    subresource_names              = ["vault"]
  }

  private_dns_zone_group {
    name                 = "kv-dns"
    private_dns_zone_ids = [azurerm_private_dns_zone.zones["vault"].id]
  }
}
