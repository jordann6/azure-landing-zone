output "portal_url" {
  description = "Public entry point (Front Door)."
  value       = "https://${azurerm_cdn_frontdoor_endpoint.portal.host_name}"
}

output "frontdoor_profile_id" {
  value = azurerm_cdn_frontdoor_profile.portal.id
}

output "aca_environment_ids" {
  description = "Container Apps environment IDs, for approving the Front Door private endpoint connections."
  value       = { for k, v in azapi_resource.aca_env : k => v.id }
}

output "container_app_names" {
  value = { for k, v in azurerm_container_app.portal : k => v.name }
}

output "region_resource_groups" {
  value = { for k, v in azurerm_resource_group.region : k => v.name }
}

output "acr_name" {
  value = azurerm_container_registry.portal.name
}

output "sql_failover_group" {
  description = "Failover group name, resource group, and servers, for the drill."
  value = {
    name           = azurerm_mssql_failover_group.portal.name
    listener       = "${azurerm_mssql_failover_group.portal.name}.database.windows.net"
    resource_group = azurerm_resource_group.data.name
    primary        = azurerm_mssql_server.region["primary"].name
    secondary      = azurerm_mssql_server.region["secondary"].name
  }
}

output "apim_gateway_url" {
  value = var.enable_apim ? azurerm_api_management.portal[0].gateway_url : null
}

output "apim_demo_partner_key" {
  description = "Subscription key for the demo partner (send as Ocp-Apim-Subscription-Key)."
  value       = var.enable_apim ? azurerm_api_management_subscription.demo_partner[0].primary_key : null
  sensitive   = true
}

output "external_id_tenant_id" {
  value = local.external_id_tenant_id
}

output "external_id_subdomain" {
  description = "<subdomain>.onmicrosoft.com / <subdomain>.ciamlogin.com"
  value       = local.external_id_subdomain
}

output "region_locations" {
  value = { for k, v in local.regions : k => v.location }
}
