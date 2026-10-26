output "vnet_id" {
  description = "Proof VNet; present after a CI apply, gone after a CI destroy."
  value       = azurerm_virtual_network.ci.id
}
