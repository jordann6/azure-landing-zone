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

# Not secrets: a client ID without a matching federated token grants nothing.
# They go into repo variables for apply.yml, destroy.yml and ttl-guard.yml.
output "gha_plan_client_id" {
  description = "Client ID of the read-scoped CI identity (pull requests and main)."
  value       = azurerm_user_assigned_identity.gha_plan.client_id
}

output "gha_apply_client_id" {
  description = "Client ID of the write-scoped CI identity (prod-apply and destroy environments)."
  value       = azurerm_user_assigned_identity.gha_apply.client_id
}

output "tenant_id" {
  description = "Entra tenant the CI identities live in."
  value       = data.azurerm_client_config.current.tenant_id
}

output "subscription_id" {
  description = "Subscription the CI identities are scoped to."
  value       = data.azurerm_subscription.current.subscription_id
}
