# Private registry as the only sanctioned image source. Public registries are
# denied two ways, mirroring the AWS ECR design: the hub firewall's FQDN allowlist
# does not include Docker Hub, and the private VNet has no internet path, so a node
# cannot reach one. Images arrive only through this registry (public images via the
# cache rule, which mirrors them in where they are scanned). Mirrors
# aws-landing-zone/workload/ecr.tf.

resource "azurerm_user_assigned_identity" "acr" {
  name                = "id-${var.project}-acr"
  location            = azurerm_resource_group.prod.location
  resource_group_name = azurerm_resource_group.prod.name
  tags                = local.tags
}

resource "azurerm_role_assignment" "acr_kms" {
  scope                = azurerm_key_vault.workload.id
  role_definition_name = "Key Vault Crypto User"
  principal_id         = azurerm_user_assigned_identity.acr.principal_id
}

resource "azurerm_container_registry" "app" {
  # checkov:skip=CKV_AZURE_165:Geo-replication is a multi-region cost add; this single-region demo does not replicate the registry.
  # checkov:skip=CKV_AZURE_166:Image quarantine is a preview policy; continuous scanning is provided by Defender for Containers at the subscription level.
  # checkov:skip=CKV_AZURE_164:Content trust / signed images is a supply-chain add-on covered by the separate signing project; out of scope for this paved-road cut.
  # checkov:skip=CKV_AZURE_233:Registry zone redundancy is a cost/HA add; out of scope for the timed demo.
  name                          = "acr${var.project}prod${random_string.kv.result}"
  location                      = azurerm_resource_group.prod.location
  resource_group_name           = azurerm_resource_group.prod.name
  sku                           = "Premium" # required for CMK, private endpoint, cache
  admin_enabled                 = false
  public_network_access_enabled = false
  data_endpoint_enabled         = true
  tags                          = local.tags

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.acr.id]
  }

  encryption {
    key_vault_key_id   = azurerm_key_vault_key.data.versionless_id
    identity_client_id = azurerm_user_assigned_identity.acr.client_id
  }

  # No internet path to the registry; pulls come over the private endpoint.
  network_rule_set {
    default_action = "Deny"
  }

  retention_policy_in_days = 14

  # A tag cannot be moved to a different image once pushed.
  trust_policy_enabled = false

  depends_on = [azurerm_role_assignment.acr_kms]
}

# Pull-through cache for Microsoft Container Registry: a pull of mcr/... is mirrored
# into this registry, so even upstream images land somewhere scannable. Docker Hub
# and quay need a credential and are left as a documented addition (the AWS side
# leaves the same registries out for the same reason).
resource "azurerm_container_registry_cache_rule" "mcr" {
  name                  = "mcr-cache"
  container_registry_id = azurerm_container_registry.app.id
  source_repo           = "mcr.microsoft.com/*"
  target_repo           = "mcr/*"
}
