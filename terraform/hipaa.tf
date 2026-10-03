# ── HIPAA technical safeguards ───────────────────────────────────────────────
# Two layers, mirroring how CIS is handled in policies.tf:
#
#   1. Scoring: the built-in HITRUST/HIPAA regulatory initiative assigned at the
#      root MG, so Defender for Cloud's Regulatory Compliance blade scores every
#      tier against it alongside CIS.
#   2. Enforcement: custom Deny policies keyed on the data_classification tag. A
#      resource group tagged data_classification = phi cannot hold a Key Vault,
#      storage account, SQL server, or PostgreSQL server that is reachable from
#      the public internet, and data_classification must be one of the known
#      values so "phi" cannot be dodged with a typo.
#
# HIPAA compliance is organizational (BAA, risk analysis, workforce training).
# This file covers technical safeguards only; docs/hipaa-mapping.md maps each
# 164.312 safeguard to the resource that implements it, with honest gaps.

# HITRUST/HIPAA built-in initiative (586 policies, no required parameters).
data "azurerm_policy_set_definition" "hipaa" {
  name = "a169a624-5599-4385-a696-c8d643089fab"
}

resource "azurerm_management_group_policy_assignment" "hipaa" {
  name                 = "hitrust-hipaa"
  display_name         = "HITRUST/HIPAA (scoring only)"
  policy_definition_id = data.azurerm_policy_set_definition.hipaa.id
  management_group_id  = azurerm_management_group.root.id
  location             = var.location

  # Scoring only. enforce = false (DoNotEnforce) evaluates compliance and renders
  # the HIPAA view in Defender for Cloud, but none of the initiative's Deny or
  # deployIfNotExists effects act. The preventive HIPAA controls are the custom
  # phi policies below, which are deliberate and tested. Because nothing
  # remediates, the identity Azure requires for an initiative with DINE/modify
  # policies is granted no role (unlike the CIS assignment).
  enforce = false

  identity {
    type = "SystemAssigned"
  }

  depends_on = [azurerm_management_group_subscription_association.workloads]
}

# ── data_classification allowed values ──────────────────────────────────────
locals {
  data_classifications = ["public", "internal", "confidential", "phi"]
}

resource "azurerm_policy_definition" "allowed_data_classification" {
  name        = "allowed-data-classification"
  policy_type = "Custom"
  # mode All so resource groups are evaluated (Indexed skips them).
  mode                = "All"
  display_name        = "Allowed data_classification values on resource groups"
  management_group_id = azurerm_management_group.root.id

  parameters = jsonencode({
    allowedValues = {
      type = "Array"
      metadata = {
        displayName = "Allowed values"
        description = "The only values data_classification may take."
      }
    }
  })

  policy_rule = jsonencode({
    "if" = {
      allOf = [
        {
          field  = "type"
          equals = "Microsoft.Resources/subscriptions/resourceGroups"
        },
        {
          field  = "tags['data_classification']"
          exists = "true"
        },
        {
          not = {
            field = "tags['data_classification']"
            "in"  = "[parameters('allowedValues')]"
          }
        }
      ]
    }
    "then" = {
      effect = "Deny"
    }
  })
}

resource "azurerm_management_group_policy_assignment" "allowed_data_classification" {
  name                 = "allowed-data-class"
  display_name         = "Allowed data_classification values on resource groups"
  policy_definition_id = azurerm_policy_definition.allowed_data_classification.id
  management_group_id  = azurerm_management_group.workloads.id

  parameters = jsonencode({
    allowedValues = { value = local.data_classifications }
  })

  depends_on = [azurerm_management_group_subscription_association.workloads]
}

# ── phi resource groups: no public network access on data services ──────────
# Keyed on the resource group's tag, so classification drives the control:
# tag the RG phi and every data service in it must be private. Each service
# must set publicNetworkAccess to Disabled explicitly; an absent value is
# treated as public.
resource "azurerm_policy_definition" "phi_deny_public_network" {
  name                = "phi-deny-public-network"
  policy_type         = "Custom"
  mode                = "Indexed"
  display_name        = "PHI resource groups: deny public network access on data services"
  management_group_id = azurerm_management_group.root.id

  parameters = jsonencode({
    effect = {
      type          = "String"
      allowedValues = ["Deny", "Audit", "Disabled"]
      defaultValue  = "Deny"
      metadata = {
        displayName = "Effect"
        description = "Deny blocks the request; Audit only reports it."
      }
    }
  })

  policy_rule = jsonencode({
    "if" = {
      allOf = [
        {
          value  = "[resourceGroup().tags['data_classification']]"
          equals = "phi"
        },
        {
          anyOf = [
            {
              allOf = [
                { field = "type", equals = "Microsoft.KeyVault/vaults" },
                { field = "Microsoft.KeyVault/vaults/publicNetworkAccess", notEquals = "Disabled" }
              ]
            },
            {
              allOf = [
                { field = "type", equals = "Microsoft.Storage/storageAccounts" },
                { field = "Microsoft.Storage/storageAccounts/publicNetworkAccess", notEquals = "Disabled" }
              ]
            },
            {
              allOf = [
                { field = "type", equals = "Microsoft.Sql/servers" },
                { field = "Microsoft.Sql/servers/publicNetworkAccess", notEquals = "Disabled" }
              ]
            },
            {
              allOf = [
                { field = "type", equals = "Microsoft.DBforPostgreSQL/flexibleServers" },
                { field = "Microsoft.DBForPostgreSql/flexibleServers/network.publicNetworkAccess", notEquals = "Disabled" }
              ]
            }
          ]
        }
      ]
    }
    "then" = {
      effect = "[parameters('effect')]"
    }
  })
}

resource "azurerm_management_group_policy_assignment" "phi_deny_public_network" {
  name                 = "phi-deny-public-net"
  display_name         = "PHI resource groups: deny public network access on data services"
  policy_definition_id = azurerm_policy_definition.phi_deny_public_network.id
  management_group_id  = azurerm_management_group.workloads.id

  depends_on = [azurerm_management_group_subscription_association.workloads]
}
