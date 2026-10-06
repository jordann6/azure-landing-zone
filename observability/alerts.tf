# ── Control-plane change alerts (CIS Azure Foundations 5.2.x and friends) ────
# The base root alerts on what was refused (Deny policy, Key Vault 403, firewall
# spikes). These alert on what was allowed but should never happen quietly:
# someone changed a guardrail, a network boundary, a role, or the security
# tooling itself. Activity log alerts are free and have no ingestion lag, so they
# fire within minutes of the change. All route to the base ops action group.

locals {
  change_alerts = {
    policy-assignment-write = { op = "Microsoft.Authorization/policyAssignments/write", what = "A policy assignment was created or changed." }
    policy-assignment-del   = { op = "Microsoft.Authorization/policyAssignments/delete", what = "A policy assignment was deleted: a guardrail was removed." }
    nsg-write               = { op = "Microsoft.Network/networkSecurityGroups/write", what = "A network security group was created or changed." }
    nsg-delete              = { op = "Microsoft.Network/networkSecurityGroups/delete", what = "A network security group was deleted." }
    nsg-rule-write          = { op = "Microsoft.Network/networkSecurityGroups/securityRules/write", what = "A network security group rule was created or changed." }
    nsg-rule-delete         = { op = "Microsoft.Network/networkSecurityGroups/securityRules/delete", what = "A network security group rule was deleted." }
    firewall-policy-write   = { op = "Microsoft.Network/firewallPolicies/write", what = "The hub firewall policy was created or changed." }
    firewall-policy-delete  = { op = "Microsoft.Network/firewallPolicies/delete", what = "The hub firewall policy was deleted." }
    security-solution-write = { op = "Microsoft.Security/securitySolutions/write", what = "A security solution was created or changed." }
    security-solution-del   = { op = "Microsoft.Security/securitySolutions/delete", what = "A security solution was deleted." }
    role-assignment-write   = { op = "Microsoft.Authorization/roleAssignments/write", what = "A role assignment was created: access was granted." }
    role-assignment-delete  = { op = "Microsoft.Authorization/roleAssignments/delete", what = "A role assignment was deleted." }
    keyvault-delete         = { op = "Microsoft.KeyVault/vaults/delete", what = "A Key Vault was deleted (purge protection still holds the keys)." }
  }
}

resource "azurerm_monitor_activity_log_alert" "change" {
  for_each = local.change_alerts

  name                = "alert-${var.project}-${each.key}"
  location            = "global"
  resource_group_name = local.logging_rg
  scopes              = [data.azurerm_subscription.current.id]
  description         = each.value.what
  tags                = local.tags

  criteria {
    category       = "Administrative"
    operation_name = each.value.op
  }

  action {
    action_group_id = local.action_group_id
  }

  lifecycle {
    precondition {
      condition     = local.base_ready
      error_message = "The base landing zone (terraform/) must be deployed first: ops_action_group_id is missing from its state."
    }
  }
}
