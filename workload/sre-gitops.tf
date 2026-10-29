# In-cluster GitOps for the SRE demo. The managed Flux extension reconciles
# gitops/ from this repository: infra (namespaces, StorageClass, secret provider
# classes), apps (slo-demo, its load generator, Grafana) and data (the Postgres
# StatefulSet and its writer). After this applies, a change reaches the cluster
# through a Git commit, not kubectl.
#
# Values that only exist after apply (the registry name, identity client IDs, the
# workspace query endpoint) reach the manifests through Flux post-build
# substitution, so Git carries image digests and structure but no
# environment-specific IDs.
#
# Secrets never enter Git: the database and Grafana admin passwords are
# generated here, stored in the workload Key Vault, and mounted into pods by the
# Secrets Store CSI driver over workload identity. Each identity can read only its
# own secret.

resource "azurerm_kubernetes_cluster_extension" "flux" {
  count          = local.sre_count
  name           = "flux"
  cluster_id     = azurerm_kubernetes_cluster.prod.id
  extension_type = "microsoft.flux"

  depends_on = [azurerm_firewall_policy_rule_collection_group.sre]
}

locals {
  gitops_substitutions = var.enable_sre_demo ? {
    ACR_LOGIN_SERVER   = azurerm_container_registry.app.login_server
    TENANT_ID          = data.azurerm_client_config.current.tenant_id
    KEY_VAULT_NAME     = azurerm_key_vault.workload.name
    DES_ID             = azurerm_disk_encryption_set.aks.id
    AMW_QUERY_ENDPOINT = azurerm_monitor_workspace.sre[0].query_endpoint
    GRAFANA_CLIENT_ID  = azurerm_user_assigned_identity.grafana[0].client_id
    DATA_CLIENT_ID     = azurerm_user_assigned_identity.slo_data[0].client_id
    CLUSTER_NAME       = azurerm_kubernetes_cluster.prod.name
  } : {}
}

resource "azurerm_kubernetes_flux_configuration" "sre" {
  count      = local.sre_count
  name       = "sre-demo"
  cluster_id = azurerm_kubernetes_cluster.prod.id
  namespace  = "flux-system"
  scope      = "cluster"

  git_repository {
    url                      = var.gitops_repo_url
    reference_type           = "branch"
    reference_value          = var.gitops_branch
    sync_interval_in_seconds = 60
    timeout_in_seconds       = 120
  }

  kustomizations {
    name                       = "infra"
    path                       = "./gitops/infra"
    garbage_collection_enabled = true
    sync_interval_in_seconds   = 60
    retry_interval_in_seconds  = 60
    post_build {
      substitute = local.gitops_substitutions
    }
  }

  kustomizations {
    name                       = "apps"
    path                       = "./gitops/apps"
    depends_on                 = ["infra"]
    garbage_collection_enabled = true
    sync_interval_in_seconds   = 60
    retry_interval_in_seconds  = 60
    post_build {
      substitute = local.gitops_substitutions
    }
  }

  # Owns the stateful namespace. The restore drill suspends this one kustomization
  # so Flux does not recreate the namespace while the restore runs.
  kustomizations {
    name                       = "data"
    path                       = "./gitops/data"
    depends_on                 = ["infra"]
    garbage_collection_enabled = true
    sync_interval_in_seconds   = 60
    retry_interval_in_seconds  = 60
    post_build {
      substitute = local.gitops_substitutions
    }
  }

  # aks_admin is scoped to the cluster, so it cannot outlive it, but this edge
  # keeps the operator's kubectl access until the configuration is gone. If a
  # delete hangs, the cluster can still be inspected.
  depends_on = [
    azurerm_kubernetes_cluster_extension.flux,
    azurerm_role_assignment.aks_acr_pull,
    azurerm_role_assignment.aks_admin,
  ]
}

# ── Secrets in Key Vault, one identity per consumer ──────────────────────────

resource "random_password" "slo_data_db" {
  count   = local.sre_count
  length  = 32
  special = false
}

resource "random_password" "grafana_admin" {
  count   = local.sre_count
  length  = 32
  special = false
}

resource "azurerm_key_vault_secret" "slo_data_db" {
  # checkov:skip=CKV_AZURE_41:Demo credential lives only for the session and is destroyed with the root; rotation is out of scope for a timed drill.
  count        = local.sre_count
  name         = "slo-data-db-password"
  value        = random_password.slo_data_db[0].result
  key_vault_id = azurerm_key_vault.workload.id
  content_type = "text/plain"

  depends_on = [azurerm_role_assignment.kv_deployer_secrets]
}

resource "azurerm_key_vault_secret" "grafana_admin" {
  # checkov:skip=CKV_AZURE_41:Demo credential lives only for the session and is destroyed with the root; rotation is out of scope for a timed drill.
  count        = local.sre_count
  name         = "grafana-admin-password"
  value        = random_password.grafana_admin[0].result
  key_vault_id = azurerm_key_vault.workload.id
  content_type = "text/plain"

  depends_on = [azurerm_role_assignment.kv_deployer_secrets]
}

# The stateful namespace's pods (Postgres and the writer) share one service
# account and read only the database password.
resource "azurerm_user_assigned_identity" "slo_data" {
  count               = local.sre_count
  name                = "id-${var.project}-slo-data"
  location            = azurerm_resource_group.prod.location
  resource_group_name = azurerm_resource_group.prod.name
  tags                = local.tags
}

resource "azurerm_federated_identity_credential" "slo_data" {
  count               = local.sre_count
  name                = "slo-data"
  resource_group_name = azurerm_resource_group.prod.name
  parent_id           = azurerm_user_assigned_identity.slo_data[0].id
  audience            = ["api://AzureADTokenExchange"]
  issuer              = azurerm_kubernetes_cluster.prod.oidc_issuer_url
  subject             = "system:serviceaccount:${local.data_namespace}:slo-data"
}

resource "azurerm_role_assignment" "slo_data_secret" {
  count                = local.sre_count
  scope                = azurerm_key_vault_secret.slo_data_db[0].resource_versionless_id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_user_assigned_identity.slo_data[0].principal_id
  principal_type       = "ServicePrincipal"
}

# Grafana reads its admin password and queries the workspace, nothing else.
resource "azurerm_user_assigned_identity" "grafana" {
  count               = local.sre_count
  name                = "id-${var.project}-grafana"
  location            = azurerm_resource_group.prod.location
  resource_group_name = azurerm_resource_group.prod.name
  tags                = local.tags
}

resource "azurerm_federated_identity_credential" "grafana" {
  count               = local.sre_count
  name                = "grafana"
  resource_group_name = azurerm_resource_group.prod.name
  parent_id           = azurerm_user_assigned_identity.grafana[0].id
  audience            = ["api://AzureADTokenExchange"]
  issuer              = azurerm_kubernetes_cluster.prod.oidc_issuer_url
  subject             = "system:serviceaccount:${local.obs_namespace}:grafana"
}

resource "azurerm_role_assignment" "grafana_secret" {
  count                = local.sre_count
  scope                = azurerm_key_vault_secret.grafana_admin[0].resource_versionless_id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_user_assigned_identity.grafana[0].principal_id
  principal_type       = "ServicePrincipal"
}

resource "azurerm_role_assignment" "grafana_amw" {
  count                = local.sre_count
  scope                = azurerm_monitor_workspace.sre[0].id
  role_definition_name = "Monitoring Data Reader"
  principal_id         = azurerm_user_assigned_identity.grafana[0].principal_id
  principal_type       = "ServicePrincipal"
}
