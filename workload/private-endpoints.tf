# Private endpoints for the private cluster. With no internet path, the nodes reach
# the container registry and the Key Vault over Private Link, resolved by private
# DNS zones linked to the prod VNet. This is what lets the cluster pull images and
# the workload read secrets with no public path at all. Mirrors the interface
# endpoints in aws-scp-governance/workload/endpoints.tf (ECR, secrets, etc.).

locals {
  private_dns_zones = {
    acr = "privatelink.azurecr.io"
    kv  = "privatelink.vaultcore.azure.net"
  }
}

resource "azurerm_private_dns_zone" "pe" {
  for_each            = local.private_dns_zones
  name                = each.value
  resource_group_name = azurerm_resource_group.prod.name
  tags                = local.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "pe" {
  for_each              = local.private_dns_zones
  name                  = "${each.key}-to-prod"
  resource_group_name   = azurerm_resource_group.prod.name
  private_dns_zone_name = azurerm_private_dns_zone.pe[each.key].name
  virtual_network_id    = azurerm_virtual_network.prod.id
  registration_enabled  = false
  tags                  = local.tags
}

resource "azurerm_private_endpoint" "acr" {
  name                = "pe-${var.project}-acr"
  location            = azurerm_resource_group.prod.location
  resource_group_name = azurerm_resource_group.prod.name
  subnet_id           = azurerm_subnet.pe.id
  tags                = local.tags

  private_service_connection {
    name                           = "acr"
    private_connection_resource_id = azurerm_container_registry.app.id
    subresource_names              = ["registry"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "acr"
    private_dns_zone_ids = [azurerm_private_dns_zone.pe["acr"].id]
  }
}

resource "azurerm_private_endpoint" "kv" {
  name                = "pe-${var.project}-kv"
  location            = azurerm_resource_group.prod.location
  resource_group_name = azurerm_resource_group.prod.name
  subnet_id           = azurerm_subnet.pe.id
  tags                = local.tags

  private_service_connection {
    name                           = "kv"
    private_connection_resource_id = azurerm_key_vault.workload.id
    subresource_names              = ["vault"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "kv"
    private_dns_zone_ids = [azurerm_private_dns_zone.pe["kv"].id]
  }
}
