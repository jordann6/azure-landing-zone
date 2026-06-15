output "management_group_hierarchy" {
  description = "Management group resource IDs"
  value = {
    root      = azurerm_management_group.root.id
    platform  = azurerm_management_group.platform.id
    workloads = azurerm_management_group.workloads.id
    sandbox   = azurerm_management_group.sandbox.id
  }
}

output "hub_vnet_id" {
  description = "Hub VNet resource ID"
  value       = azurerm_virtual_network.hub.id
}

output "spoke_platform_vnet_id" {
  description = "Platform spoke VNet resource ID"
  value       = module.spoke_platform.vnet_id
}

output "spoke_sandbox_vnet_id" {
  description = "Sandbox spoke VNet resource ID"
  value       = module.spoke_sandbox.vnet_id
}

output "policy_assignment_ids" {
  description = "Policy assignment resource IDs"
  value = {
    require_owner_tag  = azurerm_management_group_policy_assignment.require_owner_tag.id
    deny_public_ip     = azurerm_management_group_policy_assignment.deny_public_ip.id
    allowed_locations  = azurerm_management_group_policy_assignment.allowed_locations.id
  }
}
