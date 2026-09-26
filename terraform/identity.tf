# ── Human identity: personas, MG-scope RBAC, PIM JIT ─────────────────────────
# Seven least-privilege persona groups bound at management-group scope, so access
# inherits down the tier tree. Prod write is NOT standing: the platform-eng group
# holds only Reader at Prod and gets Contributor via PIM eligibility (JIT).
#
# Gated on create_entra_identity: creating Entra groups needs tenant Graph
# permissions, and PIM needs Entra ID P2. Where the demo tenant lacks them, set
# create_entra_identity = false and the persona-by-scope design still ships in
# docs/access-model.md. The well-known Contributor role definition ID is used
# directly to avoid a credentialed data lookup.

locals {
  contributor_role_id = "/providers/Microsoft.Authorization/roleDefinitions/b24988ac-6180-42a0-ab88-20f7382dd24c"

  personas = var.create_entra_identity ? toset([
    "admin",
    "platform-eng",
    "junior-eng",
    "manager",
    "finops",
    "security",
    "break-glass",
  ]) : toset([])

  # Standing role bindings (no standing prod write; that is PIM-only below).
  role_bindings = var.create_entra_identity ? {
    admin-root         = { group = "admin", scope = azurerm_management_group.root.id, role = "Owner" }
    platform-workloads = { group = "platform-eng", scope = azurerm_management_group.workloads.id, role = "Contributor" }
    platform-prod-read = { group = "platform-eng", scope = azurerm_management_group.prod.id, role = "Reader" }
    junior-dev         = { group = "junior-eng", scope = azurerm_management_group.dev.id, role = "Reader" }
    manager-root       = { group = "manager", scope = azurerm_management_group.root.id, role = "Reader" }
    finops-root        = { group = "finops", scope = azurerm_management_group.root.id, role = "Cost Management Reader" }
    security-root      = { group = "security", scope = azurerm_management_group.root.id, role = "Security Reader" }
    breakglass-root    = { group = "break-glass", scope = azurerm_management_group.root.id, role = "Owner" }
  } : {}
}

resource "azuread_group" "personas" {
  for_each = local.personas

  display_name     = "lz-${each.value}"
  security_enabled = true
}

resource "azurerm_role_assignment" "personas" {
  for_each = local.role_bindings

  scope                = each.value.scope
  role_definition_name = each.value.role
  principal_id         = azuread_group.personas[each.value.group].object_id
}

# JIT prod write: platform engineers are eligible for Contributor at Prod and
# must activate it through PIM (time-bound, approver-gated in the portal).
resource "azurerm_pim_eligible_role_assignment" "prod_write" {
  count = (var.create_entra_identity && var.enable_pim) ? 1 : 0

  scope              = azurerm_management_group.prod.id
  role_definition_id = local.contributor_role_id
  principal_id       = azuread_group.personas["platform-eng"].object_id

  justification = "JIT prod-write for platform engineers (no standing prod write)."

  schedule {
    expiration {
      duration_days = 365
    }
  }
}
