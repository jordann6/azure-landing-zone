# AKS as the paved-road cluster. The load-bearing controls mirror the AWS EKS in
# aws-landing-zone/workload/eks.tf: a private API server (no public control
# plane), CMK envelope encryption of Kubernetes secrets in etcd (Key Vault KMS),
# and an OIDC issuer + workload identity so pods get scoped Entra identities instead
# of node credentials or static keys. Egress leaves only through the hub firewall
# (outbound_type = userDefinedRouting), and the node OS disks are CMK-encrypted.

# User-assigned control-plane identity, created first so it can be granted access
# to the etcd CMK and the prod network before the cluster references them.
resource "azurerm_user_assigned_identity" "aks" {
  name                = "id-${var.project}-aks"
  location            = azurerm_resource_group.prod.location
  resource_group_name = azurerm_resource_group.prod.name
  tags                = local.tags
}

# The cluster identity manages the custom VNet (subnet join, the UDR route table).
resource "azurerm_role_assignment" "aks_network" {
  scope                = azurerm_resource_group.prod.id
  role_definition_name = "Network Contributor"
  principal_id         = azurerm_user_assigned_identity.aks.principal_id
}

# The cluster identity uses the etcd CMK for KMS envelope encryption.
resource "azurerm_role_assignment" "aks_kms" {
  scope                = azurerm_key_vault.workload.id
  role_definition_name = "Key Vault Crypto User"
  principal_id         = azurerm_user_assigned_identity.aks.principal_id
}

# With Private KMS + API Server VNet Integration, AKS provisions its own managed
# private endpoint to the workload Key Vault (in the node resource group) to reach
# the etcd CMK. Approving that connection needs the KV private-endpoint proxy +
# approval actions, which no built-in Crypto/Network role grants. This least-
# privilege custom role covers exactly those management-plane actions on the vault,
# keeping the vault default-Deny and the identity scoped to just what KMS needs.
resource "azurerm_role_definition" "aks_kv_kms_pe" {
  name              = "aks-kms-pe-approver-${var.project}"
  scope             = azurerm_key_vault.workload.id
  description       = "Lets the AKS control-plane identity create and approve the KMS private endpoint connection on the workload Key Vault."
  assignable_scopes = [azurerm_key_vault.workload.id]

  permissions {
    actions = [
      "Microsoft.KeyVault/vaults/read",
      "Microsoft.KeyVault/vaults/privateEndpointConnectionProxies/read",
      "Microsoft.KeyVault/vaults/privateEndpointConnectionProxies/write",
      "Microsoft.KeyVault/vaults/privateEndpointConnectionProxies/delete",
      "Microsoft.KeyVault/vaults/privateEndpointConnectionProxies/validate/action",
      "Microsoft.KeyVault/vaults/PrivateEndpointConnectionsApproval/action",
    ]
  }
}

resource "azurerm_role_assignment" "aks_kv_kms_pe" {
  scope              = azurerm_key_vault.workload.id
  role_definition_id = azurerm_role_definition.aks_kv_kms_pe.role_definition_resource_id
  principal_id       = azurerm_user_assigned_identity.aks.principal_id
}

resource "azurerm_kubernetes_cluster" "prod" {
  # checkov:skip=CKV_AZURE_170:Free tier (no uptime-SLA paid SKU) keeps the timed demo inside the cost ceiling; the paid SKU is the production upgrade.
  # checkov:skip=CKV_AZURE_232:Single node pool runs the workloads, mirroring the one AWS EKS managed node group; a dedicated system pool is the production split.
  # checkov:skip=CKV_AZURE_226:Node OS disks are CMK-encrypted via the disk encryption set; ephemeral OS disks are an unrelated performance option.
  # checkov:skip=CKV_AZURE_227:Host-based encryption needs the EncryptionAtHost subscription feature registered; CMK disks cover the disk-encryption requirement here.
  # checkov:skip=CKV_AZURE_168:API-server authorized IP ranges do not apply to a private cluster (the control plane has no public endpoint).
  name                = "aks-${var.project}-prod"
  location            = azurerm_resource_group.prod.location
  resource_group_name = azurerm_resource_group.prod.name
  dns_prefix          = "${var.project}-prod"
  # No version pin: AKS selects a version supported in the region (a pinned minor
  # can be unsupported in a given region). Upgrades are handled by the patch channel.
  node_resource_group = "rg-${var.project}-prod-aks-nodes"
  tags                = local.tags

  # No public control plane; the API server is private and resolvable only over the
  # hub/spoke network. AKS manages the private DNS zone.
  private_cluster_enabled             = true
  private_cluster_public_fqdn_enabled = false
  private_dns_zone_id                 = "System"

  # Workload identity (the IRSA analog) and hardened access.
  oidc_issuer_enabled       = true
  workload_identity_enabled = true
  local_account_disabled    = true
  azure_policy_enabled      = true
  automatic_channel_upgrade = "patch"

  # Secrets Store CSI driver with autorotation, so the ESO/CSI secret path stays
  # in sync with Key Vault.
  key_vault_secrets_provider {
    secret_rotation_enabled = true
  }

  azure_active_directory_role_based_access_control {
    managed            = true
    azure_rbac_enabled = true
  }

  # CMK envelope encryption of Kubernetes secrets in etcd (mirrors the AWS EKS
  # encryption_config with the KMS key over the "secrets" resource).
  # Reach the etcd CMK over the Key Vault private endpoint, so the vault stays
  # locked to default-Deny (no public exposure needed for KMS).
  key_management_service {
    key_vault_key_id         = azurerm_key_vault_key.etcd.id
    key_vault_network_access = "Private"
  }

  # Private KMS (above) requires API Server VNet Integration: the control plane is
  # projected into the delegated api-server subnet so it can reach the etcd CMK over
  # the Key Vault private endpoint. Compatible with the private cluster.
  api_server_access_profile {
    vnet_integration_enabled = true
    subnet_id                = azurerm_subnet.apiserver.id
  }

  # CMK for the node OS/data disks.
  disk_encryption_set_id = azurerm_disk_encryption_set.aks.id

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.aks.id]
  }

  default_node_pool {
    name                         = "system"
    vm_size                      = var.aks_node_vm_size
    node_count                   = var.aks_node_count
    vnet_subnet_id               = azurerm_subnet.aks.id
    os_sku                       = "Ubuntu"
    only_critical_addons_enabled = false # single pool runs workloads, mirrors the AWS node group
    temporary_name_for_rotation  = "systmp"

    # Match the surge Azure applies by default so Terraform does not drift on it.
    upgrade_settings {
      max_surge = "10%"
    }
  }

  network_profile {
    network_plugin      = "azure"
    network_plugin_mode = "overlay"
    network_policy      = "calico"
    load_balancer_sku   = "standard"
    outbound_type       = "userDefinedRouting" # egress via the hub firewall only
    service_cidr        = var.aks_service_cidr
    dns_service_ip      = var.aks_dns_service_ip
    pod_cidr            = var.aks_pod_cidr
  }

  oms_agent {
    log_analytics_workspace_id = local.law_id
  }

  # The UDR egress route, the network role, and the etcd-key access must all exist
  # before the cluster provisions (outbound_type=UDR needs the route in place; the
  # firewall must already allow AKS's required FQDNs, see aks-egress-firewall.tf).
  depends_on = [
    azurerm_subnet_route_table_association.aks,
    azurerm_role_assignment.aks_network,
    azurerm_role_assignment.aks_kms,
    azurerm_role_assignment.aks_kv_kms_pe,
    azurerm_firewall_policy_rule_collection_group.aks_egress,
  ]
}

# The deployer keeps kubectl access even though local accounts are disabled: Entra
# RBAC cluster-admin scoped to this cluster (no static kubeconfig secret).
resource "azurerm_role_assignment" "aks_admin" {
  scope                = azurerm_kubernetes_cluster.prod.id
  role_definition_name = "Azure Kubernetes Service RBAC Cluster Admin"
  principal_id         = data.azurerm_client_config.current.object_id
}

# Full control-plane audit logging to the central workspace (mirrors the AWS
# enabled_cluster_log_types: api, audit, authenticator, controllerManager, scheduler).
resource "azurerm_monitor_diagnostic_setting" "aks" {
  name                       = "aks-audit"
  target_resource_id         = azurerm_kubernetes_cluster.prod.id
  log_analytics_workspace_id = local.law_id

  enabled_log { category = "kube-apiserver" }
  enabled_log { category = "kube-audit" }
  enabled_log { category = "kube-audit-admin" }
  enabled_log { category = "kube-controller-manager" }
  enabled_log { category = "kube-scheduler" }
  enabled_log { category = "guard" }

  metric {
    category = "AllMetrics"
    enabled  = false
  }
}
