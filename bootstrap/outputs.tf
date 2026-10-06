output "resource_group_name" {
  description = "State backend resource group."
  value       = azurerm_resource_group.state.name
}

output "storage_account_name" {
  description = "State storage account; every root's backend block points here."
  value       = azurerm_storage_account.state.name
}

output "container_name" {
  description = "State container."
  value       = azurerm_storage_container.tfstate.name
}
