output "prod_vnet_id" {
  value = azurerm_virtual_network.prod.id
}

output "aks_cluster_name" {
  value = azurerm_kubernetes_cluster.prod.name
}

output "aks_private_fqdn" {
  description = "Private AKS API FQDN (reachable only over the hub/spoke network)."
  value       = azurerm_kubernetes_cluster.prod.private_fqdn
}

output "aks_oidc_issuer_url" {
  value = azurerm_kubernetes_cluster.prod.oidc_issuer_url
}

output "acr_login_server" {
  value = azurerm_container_registry.app.login_server
}

output "postgres_fqdn" {
  description = "Private PostgreSQL FQDN."
  value       = one(azurerm_postgresql_flexible_server.prod[*].fqdn)
}

output "postgres_admin_secret_id" {
  description = "Key Vault secret holding the PostgreSQL admin credential (read by the ESO workload identity)."
  value       = one(azurerm_key_vault_secret.pg_admin[*].id)
}

output "external_secrets_identity_client_id" {
  description = "Client ID of the workload identity federated to external-secrets/external-secrets."
  value       = azurerm_user_assigned_identity.eso.client_id
}

output "workload_key_vault_id" {
  value = azurerm_key_vault.workload.id
}

output "backup_vault_id" {
  value = azurerm_data_protection_backup_vault.prod.id
}

output "kubelet_identity_object_id" {
  description = "Object ID of the node pool identity (holds AcrPull on the registry)."
  value       = azurerm_kubernetes_cluster.prod.kubelet_identity[0].object_id
}

output "acr_name" {
  description = "Registry name for az acr import."
  value       = azurerm_container_registry.app.name
}

output "monitor_workspace_query_endpoint" {
  description = "Prometheus query endpoint of the Azure Monitor workspace; null when enable_sre_demo is off."
  value       = one(azurerm_monitor_workspace.sre[*].query_endpoint)
}

output "monitor_workspace_id" {
  value = one(azurerm_monitor_workspace.sre[*].id)
}

output "flux_configuration_name" {
  value = one(azurerm_kubernetes_flux_configuration.sre[*].name)
}

output "aks_backup_vault_name" {
  description = "Demo-only backup vault (soft delete Off); null when enable_aks_backup is off."
  value       = one(azurerm_data_protection_backup_vault.aks_demo[*].name)
}

output "aks_backup_instance_name" {
  value = one(azurerm_data_protection_backup_instance_kubernetes_cluster.aks_demo[*].name)
}

output "aks_snapshot_resource_group" {
  value = one(azurerm_resource_group.aks_snapshots[*].name)
}

output "resource_group_name" {
  value = azurerm_resource_group.prod.name
}
