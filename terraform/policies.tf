# ── Custom policy definitions (defined at the root MG, inherited down) ────────
# All effects are Deny, not Audit: a preventive guardrail must block the action,
# matching the AWS SCP posture on the other side of the portfolio.

resource "azurerm_policy_definition" "require_owner_tag" {
  name                = "require-owner-tag"
  policy_type         = "Custom"
  mode                = "Indexed"
  display_name        = "Require owner tag on resource groups"
  management_group_id = azurerm_management_group.root.id

  policy_rule = jsonencode({
    "if" = {
      allOf = [
        {
          field  = "type"
          equals = "Microsoft.Resources/subscriptions/resourceGroups"
        },
        {
          field  = "tags['owner']"
          exists = "false"
        }
      ]
    }
    "then" = {
      effect = "Deny"
    }
  })
}

resource "azurerm_policy_definition" "deny_public_ip" {
  name                = "deny-public-ip"
  policy_type         = "Custom"
  mode                = "Indexed"
  display_name        = "Deny public IP creation"
  management_group_id = azurerm_management_group.root.id

  policy_rule = jsonencode({
    "if" = {
      field  = "type"
      equals = "Microsoft.Network/publicIPAddresses"
    }
    "then" = {
      effect = "Deny"
    }
  })
}

resource "azurerm_policy_definition" "allowed_locations" {
  name                = "allowed-locations"
  policy_type         = "Custom"
  mode                = "Indexed"
  display_name        = "Allowed resource locations"
  management_group_id = azurerm_management_group.root.id

  parameters = jsonencode({
    allowedLocations = {
      type = "Array"
      metadata = {
        displayName = "Allowed locations"
        description = "List of allowed Azure regions"
      }
    }
  })

  policy_rule = jsonencode({
    "if" = {
      allOf = [
        {
          field     = "location"
          notEquals = "global"
        },
        {
          not = {
            field = "location"
            "in"  = "[parameters('allowedLocations')]"
          }
        }
      ]
    }
    "then" = {
      effect = "Deny"
    }
  })
}

# Parameterized tag-enforcement policy, assigned once per required tag below.
resource "azurerm_policy_definition" "require_tag" {
  name                = "require-tag-on-rg"
  policy_type         = "Custom"
  mode                = "Indexed"
  display_name        = "Require a named tag on resource groups"
  management_group_id = azurerm_management_group.root.id

  parameters = jsonencode({
    tagName = {
      type = "String"
      metadata = {
        displayName = "Tag name"
        description = "The tag that every resource group must carry."
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
          field  = "[concat('tags[', parameters('tagName'), ']')]"
          exists = "false"
        }
      ]
    }
    "then" = {
      effect = "Deny"
    }
  })
}

# ── Assignments at the Workloads MG (inherited by Dev / Test / Prod) ──────────

resource "azurerm_management_group_policy_assignment" "require_owner_tag" {
  name                 = "req-owner-tag"
  display_name         = "Require owner tag on resource groups"
  policy_definition_id = azurerm_policy_definition.require_owner_tag.id
  management_group_id  = azurerm_management_group.workloads.id

  depends_on = [azurerm_management_group_subscription_association.workloads]
}

resource "azurerm_management_group_policy_assignment" "deny_public_ip" {
  name                 = "deny-public-ip"
  display_name         = "Deny public IP creation"
  policy_definition_id = azurerm_policy_definition.deny_public_ip.id
  management_group_id  = azurerm_management_group.workloads.id

  # Azure Firewall and Bastion legitimately need public IPs and live in the hub
  # RGs, which sit under Platform, not Workloads, so no exclusion is needed here.
  depends_on = [azurerm_management_group_subscription_association.workloads]
}

resource "azurerm_management_group_policy_assignment" "allowed_locations" {
  name                 = "allowed-locations"
  display_name         = "Allowed resource locations"
  policy_definition_id = azurerm_policy_definition.allowed_locations.id
  management_group_id  = azurerm_management_group.workloads.id

  parameters = jsonencode({
    allowedLocations = { value = var.allowed_locations }
  })

  depends_on = [azurerm_management_group_subscription_association.workloads]
}

# One assignment per required cost/governance tag.
locals {
  required_tags = ["cost_center", "environment", "data_classification"]
}

resource "azurerm_management_group_policy_assignment" "require_tag" {
  for_each = toset(local.required_tags)

  name                 = "require-tag-${each.key}"
  display_name         = "Require ${each.key} tag on resource groups"
  policy_definition_id = azurerm_policy_definition.require_tag.id
  management_group_id  = azurerm_management_group.workloads.id

  parameters = jsonencode({
    tagName = { value = each.key }
  })

  depends_on = [azurerm_management_group_subscription_association.workloads]
}

# ── Prod stricter-by-inheritance ─────────────────────────────────────────────
# Prod inherits everything above and adds a tighter single-region lock, showing
# that lower tiers are permissive while Prod is constrained.

resource "azurerm_management_group_policy_assignment" "prod_single_region" {
  name                 = "prod-single-region"
  display_name         = "Prod: single approved region only"
  policy_definition_id = azurerm_policy_definition.allowed_locations.id
  management_group_id  = azurerm_management_group.prod.id

  parameters = jsonencode({
    allowedLocations = { value = [var.location, "global"] }
  })

  depends_on = [azurerm_management_group_subscription_association.workloads]
}

# ── Built-in CIS Microsoft Azure Foundations Benchmark initiative ────────────
# Assigned at the root MG so every tier is scored against CIS. The initiative
# contains deployIfNotExists / modify policies, so the assignment carries a
# system-assigned identity and a location; the identity is granted Contributor
# at the root MG so its remediation tasks can run. Assessment findings surface
# in Defender for Cloud's Regulatory Compliance blade (monitoring.tf).

data "azurerm_policy_set_definition" "cis" {
  display_name = "CIS Microsoft Azure Foundations Benchmark v2.0.0"
}

resource "azurerm_management_group_policy_assignment" "cis" {
  name                 = "cis-azure-foundations"
  display_name         = "CIS Microsoft Azure Foundations Benchmark"
  policy_definition_id = data.azurerm_policy_set_definition.cis.id
  management_group_id  = azurerm_management_group.root.id
  location             = var.location

  identity {
    type = "SystemAssigned"
  }

  # Report-first: the initiative's own default effects apply. Deny-capable
  # controls in the initiative are left at their built-in defaults so a demo
  # apply is not blocked by a scored control before the resource it guards
  # exists. Tighten per control once the baseline is clean.
  depends_on = [azurerm_management_group_subscription_association.workloads]
}

# The CIS assignment's managed identity needs rights to run remediation tasks.
resource "azurerm_role_assignment" "cis_remediation" {
  scope                = azurerm_management_group.root.id
  role_definition_name = "Contributor"
  principal_id         = azurerm_management_group_policy_assignment.cis.identity[0].principal_id
}
