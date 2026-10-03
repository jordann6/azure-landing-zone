# ── Entra External ID: member sign-in ───────────────────────────────────────
# Members (pharmacy staff) are customers, not employees, so they sign in
# through a separate External ID tenant rather than the workforce tenant. This
# creates the tenant; the app registration and the sign-up/sign-in user flow
# are created inside it by scripts/portal-external-id.ps1 (Microsoft Graph
# PowerShell), because they live in the new tenant's directory, not in ARM.
#
# Data residency is pinned to the United States. The base allowed-locations
# policy skips this resource type because "United States" is a geography, not
# an Azure region.

resource "azurerm_resource_group" "identity" {
  count = var.enable_external_id ? 1 : 0

  name     = "rg-${var.project}-portal-identity"
  location = var.primary_location
  tags     = merge(local.base_tags, { data_classification = "confidential" })
}

resource "azapi_resource" "external_id" {
  count = var.enable_external_id ? 1 : 0

  type      = "Microsoft.AzureActiveDirectory/ciamDirectories@2023-05-17-preview"
  name      = "alzportal${local.suffix}"
  parent_id = azurerm_resource_group.identity[0].id
  location  = "United States"
  tags      = azurerm_resource_group.identity[0].tags

  body = {
    sku = {
      name = "Standard"
      tier = "A0"
    }
    properties = {
      createTenantProperties = {
        displayName = "Member Portal (${local.suffix})"
        countryCode = "US"
      }
    }
  }

  response_export_values = ["properties.tenantId", "properties.domainName"]

  # createTenantProperties is used once at creation and never returned by a
  # read, so ignore it rather than diff on every plan.
  lifecycle {
    ignore_changes = [body]
  }
}

locals {
  external_id_tenant_id = var.enable_external_id ? azapi_resource.external_id[0].output.properties.tenantId : ""
  external_id_subdomain = var.enable_external_id ? azapi_resource.external_id[0].name : ""
}
