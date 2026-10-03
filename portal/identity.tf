# ── App identity and image registry ─────────────────────────────────────────
# One user-assigned identity for the portal app in both regions. It pulls
# images from ACR and is the Entra administrator of both SQL servers, so the
# app connects with a token and there is no database password anywhere.

resource "azurerm_user_assigned_identity" "app" {
  name                = "id-${var.project}-portal-app"
  location            = var.shared_location
  resource_group_name = azurerm_resource_group.edge.name
  tags                = azurerm_resource_group.edge.tags
}

resource "azurerm_container_registry" "portal" {
  # checkov:skip=CKV_AZURE_139:Basic SKU cannot disable public access or use private endpoints; images are built by ACR Tasks (az acr build) and pulled with a managed identity. Premium with a private endpoint is the production path, as in workload/acr.tf.
  # checkov:skip=CKV_AZURE_163:Image vulnerability scanning is Defender for Containers at the subscription level (paid plan, off by default in the base).
  # checkov:skip=CKV_AZURE_164:Content trust needs Premium; signing is covered by the separate supply-chain project.
  # checkov:skip=CKV_AZURE_165:Geo-replication needs Premium; images are small and rebuilt from source.
  # checkov:skip=CKV_AZURE_166:Image quarantine is a preview policy needing Premium.
  # checkov:skip=CKV_AZURE_167:Retention policies need Premium.
  # checkov:skip=CKV_AZURE_233:Zone redundancy needs Premium.
  # checkov:skip=CKV_AZURE_237:Dedicated data endpoints need Premium.
  name                = "acr${var.project}portal${local.suffix}"
  location            = var.shared_location
  resource_group_name = azurerm_resource_group.edge.name
  sku                 = "Basic"
  admin_enabled       = false
  tags                = azurerm_resource_group.edge.tags
}

resource "azurerm_role_assignment" "app_acr_pull" {
  scope                = azurerm_container_registry.portal.id
  role_definition_name = "AcrPull"
  principal_id         = azurerm_user_assigned_identity.app.principal_id
}
