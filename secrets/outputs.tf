output "scanner_identity_client_id" {
  description = "Client ID of the scanner's managed identity."
  value       = azurerm_user_assigned_identity.scanner.client_id
}

output "scanner_identity_principal_id" {
  description = "Object ID of the scanner identity, used by test-secrets.sh for the effective-access check."
  value       = azurerm_user_assigned_identity.scanner.principal_id
}

output "scanned_vault_ids" {
  description = "Vaults the scanner can read metadata from."
  value       = values(local.vaults)
}

output "control_secret_name" {
  description = "Positive-control secret the scanner should flag (null when disabled)."
  value       = var.enable_control_secret ? azurerm_key_vault_secret.control[0].name : null
}

# Sourced the way azure-secrets-lifecycle's `make env` is, so its scanner runs
# against this landing zone.
output "scanner_env" {
  description = "Shell exports that point the azure-secrets-lifecycle scanner at this landing zone."
  value       = <<-EOT
    export AZURE_SUBSCRIPTION_ID=${data.azurerm_subscription.current.subscription_id}
    export AZURE_CLIENT_ID=${azurerm_user_assigned_identity.scanner.client_id}
    export LOG_ANALYTICS_WORKSPACE_ID=${try(data.terraform_remote_state.base.outputs.log_analytics_workspace_guid, "")}
  EOT
}
