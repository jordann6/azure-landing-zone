# Workload identity worked example: the External Secrets Operator. Its pod assumes
# this Entra identity through the cluster OIDC issuer, scoped by Kubernetes service
# account, and can read only the PostgreSQL admin secret from the workload Key
# Vault. No static kubeconfig, no node-wide credentials: the pod gets exactly one
# secret. Mirrors aws-landing-zone/workload/irsa.tf (ESO via IRSA over OIDC).

resource "azurerm_user_assigned_identity" "eso" {
  name                = "id-${var.project}-external-secrets"
  location            = azurerm_resource_group.prod.location
  resource_group_name = azurerm_resource_group.prod.name
  tags                = local.tags
}

# Federate the Kubernetes service account external-secrets/external-secrets to the
# identity through the cluster's OIDC issuer.
resource "azurerm_federated_identity_credential" "eso" {
  name                = "external-secrets"
  resource_group_name = azurerm_resource_group.prod.name
  parent_id           = azurerm_user_assigned_identity.eso.id
  audience            = ["api://AzureADTokenExchange"]
  issuer              = azurerm_kubernetes_cluster.prod.oidc_issuer_url
  subject             = "system:serviceaccount:external-secrets:external-secrets"
}

# The identity can read only secrets from the workload vault (where the PG admin
# credential lives), nothing else.
resource "azurerm_role_assignment" "eso_kv" {
  scope                = azurerm_key_vault.workload.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_user_assigned_identity.eso.principal_id
}
