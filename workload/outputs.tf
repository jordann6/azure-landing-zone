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
  value       = azurerm_postgresql_flexible_server.prod.fqdn
}

output "postgres_admin_secret_id" {
  description = "Key Vault secret holding the PostgreSQL admin credential (read by the ESO workload identity)."
  value       = azurerm_key_vault_secret.pg_admin.id
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
