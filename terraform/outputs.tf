output "management_group_hierarchy" {
  description = "Management group resource IDs"
  value = {
    root      = azurerm_management_group.root.id
    platform  = azurerm_management_group.platform.id
    workloads = azurerm_management_group.workloads.id
    dev       = azurerm_management_group.dev.id
    test      = azurerm_management_group.test.id
    prod      = azurerm_management_group.prod.id
    sandbox   = azurerm_management_group.sandbox.id
  }
}

output "hub_vnet_id" {
  description = "Hub VNet resource ID"
  value       = azurerm_virtual_network.hub.id
}

output "compute_gallery" {
  description = "Golden-image destination and private management subnet."
  value = {
    id                   = azurerm_shared_image_gallery.hardened.id
    name                 = azurerm_shared_image_gallery.hardened.name
    resource_group_name  = azurerm_resource_group.images.name
    image_id             = azurerm_shared_image.ubuntu.id
    image_name           = azurerm_shared_image.ubuntu.name
    location             = var.location
    subscription_id      = data.azurerm_client_config.current.subscription_id
    management_subnet_id = azurerm_subnet.management.id
    project              = var.project
  }
}

output "spoke_vnet_ids" {
  description = "Spoke VNet resource IDs by tier"
  value = {
    dev     = module.spoke_dev.vnet_id
    test    = module.spoke_test.vnet_id
    sandbox = module.spoke_sandbox.vnet_id
  }
}

output "policy_assignment_ids" {
  description = "Preventive (Deny) policy assignment resource IDs"
  value = {
    require_owner_tag  = azurerm_management_group_policy_assignment.require_owner_tag.id
    deny_public_ip     = azurerm_management_group_policy_assignment.deny_public_ip.id
    allowed_locations  = azurerm_management_group_policy_assignment.allowed_locations.id
    prod_single_region = azurerm_management_group_policy_assignment.prod_single_region.id
    cis_initiative     = azurerm_management_group_policy_assignment.cis.id
  }
}

output "key_vault_id" {
  description = "CMK Key Vault resource ID (the standing residual after destroy)."
  value       = azurerm_key_vault.cmk.id
}

output "log_analytics_workspace_id" {
  description = "Central Log Analytics workspace ID."
  value       = azurerm_log_analytics_workspace.central.id
}

output "firewall_private_ip" {
  description = "Azure Firewall private IP (spoke default-route next hop); null when disabled."
  value       = var.enable_firewall ? azurerm_firewall.hub[0].ip_configuration[0].private_ip_address : null
}

output "firewall_public_ip" {
  description = "Azure Firewall public egress IP; null when disabled."
  value       = var.enable_firewall ? azurerm_public_ip.firewall[0].ip_address : null
}

output "firewall_policy_id" {
  description = "Hub firewall policy ID, so a workload root can attach its own egress rule collection (e.g. AKS required FQDNs); null when disabled."
  value       = var.enable_firewall ? azurerm_firewall_policy.hub[0].id : null
}

output "bastion_dns_name" {
  description = "Azure Bastion host name (browser admin path); null when disabled."
  value       = var.enable_bastion ? azurerm_bastion_host.hub[0].dns_name : null
}

output "fortigate_untrust_ip" {
  description = "Public IP on the FortiGate untrust interface (null when disabled)."
  value       = var.enable_fortigate ? azurerm_public_ip.fw_untrust[0].ip_address : null
}

output "ops_action_group_id" {
  description = "Ops action group, so other roots (workload, portal) route their alerts to the same place."
  value       = azurerm_monitor_action_group.ops.id
}
