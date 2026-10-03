# ── API Management: the partner API facade ──────────────────────────────────
# Members use the portal through Front Door. Partners (wholesalers, vendors)
# integrate through API Management: a subscription key per partner, a rate
# limit, and request logging to Application Insights, with Front Door and its
# WAF still in front of the backend.
#
# Consumption tier: provisions in minutes and bills per call, which suits a
# deploy-demo-destroy portfolio. Trade-off: no VNet integration, so APIM calls
# the backend through the public Front Door endpoint rather than privately.
# Standard v2 or Premium with VNet integration is the production path.

resource "azurerm_api_management" "portal" {
  # checkov:skip=CKV_AZURE_107:Consumption tier has no VNet integration (documented trade-off above).
  # checkov:skip=CKV_AZURE_174:Consumption tier cannot disable public network access; the gateway is the partner-facing entry point by design, protected by subscription keys and a rate limit.
  count = var.enable_apim ? 1 : 0

  name                = "apim-${var.project}-portal-${local.suffix}"
  location            = var.primary_location
  resource_group_name = azurerm_resource_group.edge.name
  publisher_name      = "Member Portal"
  publisher_email     = var.alert_email
  sku_name            = "Consumption_0"
  tags                = azurerm_resource_group.edge.tags

  identity {
    type = "SystemAssigned"
  }
}

resource "azurerm_api_management_api" "partner_orders" {
  count = var.enable_apim ? 1 : 0

  name                  = "partner-orders"
  resource_group_name   = azurerm_resource_group.edge.name
  api_management_name   = azurerm_api_management.portal[0].name
  revision              = "1"
  display_name          = "Partner Orders"
  path                  = "partners"
  protocols             = ["https"]
  service_url           = "https://${azurerm_cdn_frontdoor_endpoint.portal.host_name}/api"
  subscription_required = true
}

resource "azurerm_api_management_api_operation" "list_orders" {
  count = var.enable_apim ? 1 : 0

  operation_id        = "list-orders"
  api_name            = azurerm_api_management_api.partner_orders[0].name
  api_management_name = azurerm_api_management.portal[0].name
  resource_group_name = azurerm_resource_group.edge.name
  display_name        = "List recent orders"
  method              = "GET"
  url_template        = "/orders"

  response {
    status_code = 200
  }
}

# Per-subscription rate limit (rate-limit-by-key is not available on
# Consumption), and strip headers that reveal the backend.
resource "azurerm_api_management_api_policy" "partner_orders" {
  count = var.enable_apim ? 1 : 0

  api_name            = azurerm_api_management_api.partner_orders[0].name
  api_management_name = azurerm_api_management.portal[0].name
  resource_group_name = azurerm_resource_group.edge.name

  xml_content = <<-XML
    <policies>
      <inbound>
        <base />
        <rate-limit calls="60" renewal-period="60" />
      </inbound>
      <backend>
        <base />
      </backend>
      <outbound>
        <base />
        <set-header name="X-Powered-By" exists-action="delete" />
        <set-header name="Server" exists-action="delete" />
      </outbound>
      <on-error>
        <base />
      </on-error>
    </policies>
  XML
}

resource "azurerm_api_management_product" "partners" {
  count = var.enable_apim ? 1 : 0

  product_id            = "partners"
  api_management_name   = azurerm_api_management.portal[0].name
  resource_group_name   = azurerm_resource_group.edge.name
  display_name          = "Partners"
  subscription_required = true
  approval_required     = false
  published             = true
}

resource "azurerm_api_management_product_api" "partners" {
  count = var.enable_apim ? 1 : 0

  api_name            = azurerm_api_management_api.partner_orders[0].name
  product_id          = azurerm_api_management_product.partners[0].product_id
  api_management_name = azurerm_api_management.portal[0].name
  resource_group_name = azurerm_resource_group.edge.name
}

# One demo partner subscription; its key is in state (sensitive) and is read
# with `terraform output -raw apim_demo_partner_key` for the demo call.
resource "azurerm_api_management_subscription" "demo_partner" {
  count = var.enable_apim ? 1 : 0

  api_management_name = azurerm_api_management.portal[0].name
  resource_group_name = azurerm_resource_group.edge.name
  product_id          = azurerm_api_management_product.partners[0].id
  display_name        = "demo-partner"
  state               = "active"
  allow_tracing       = false
}

resource "azurerm_api_management_logger" "appinsights" {
  count = var.enable_apim ? 1 : 0

  name                = "appinsights"
  api_management_name = azurerm_api_management.portal[0].name
  resource_group_name = azurerm_resource_group.edge.name
  resource_id         = azurerm_application_insights.portal.id

  application_insights {
    instrumentation_key = azurerm_application_insights.portal.instrumentation_key
  }
}

resource "azurerm_api_management_api_diagnostic" "partner_orders" {
  count = var.enable_apim ? 1 : 0

  identifier               = "applicationinsights"
  api_name                 = azurerm_api_management_api.partner_orders[0].name
  api_management_name      = azurerm_api_management.portal[0].name
  resource_group_name      = azurerm_resource_group.edge.name
  api_management_logger_id = azurerm_api_management_logger.appinsights[0].id
  sampling_percentage      = 100
  always_log_errors        = true
  verbosity                = "information"
}
