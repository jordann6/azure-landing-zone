# ── Conditional Access: MFA baseline ─────────────────────────────────────────
# Three tenant-wide policies: block legacy authentication, require MFA for the
# privileged persona groups, and require MFA for everyone else. The break-glass
# persona (and any extra groups in conditional_access_excluded_group_ids) is
# excluded from the MFA policies so a bad policy cannot lock the tenant out.
#
# Gated on enable_conditional_access, default off: Conditional Access needs
# Entra ID P1 or P2, and it is a tenant-wide change. Policies are created in
# report-only mode by default, so sign-in logs show what would have been blocked
# before anything is enforced. Flip conditional_access_state to "enabled" only
# after reading those logs.
#
# Security Defaults and Conditional Access are mutually exclusive: the tenant
# must have Security Defaults turned off before these policies can be created.
# Terraform does not manage that setting. It is a tenant-wide change, so make it
# deliberately (see docs/access-model.md) and not as a side effect of an apply.

locals {
  ca_enabled = var.enable_conditional_access

  ca_breakglass_group_ids = var.create_entra_identity ? [azuread_group.personas["break-glass"].object_id] : []
  ca_excluded_group_ids   = concat(local.ca_breakglass_group_ids, tolist(var.conditional_access_excluded_group_ids))

  ca_privileged_group_ids = var.create_entra_identity ? [
    for name in ["admin", "platform-eng", "security"] : azuread_group.personas[name].object_id
  ] : []
}

resource "azuread_conditional_access_policy" "block_legacy_auth" {
  count = local.ca_enabled ? 1 : 0

  display_name = "lz-block-legacy-authentication"
  state        = var.conditional_access_state

  conditions {
    client_app_types = ["exchangeActiveSync", "other"]

    applications {
      included_applications = ["All"]
    }

    users {
      included_users  = ["All"]
      excluded_groups = local.ca_breakglass_group_ids
    }
  }

  grant_controls {
    operator          = "OR"
    built_in_controls = ["block"]
  }
}

resource "azuread_conditional_access_policy" "mfa_privileged" {
  count = (local.ca_enabled && var.create_entra_identity) ? 1 : 0

  display_name = "lz-require-mfa-privileged"
  state        = var.conditional_access_state

  conditions {
    client_app_types = ["all"]

    applications {
      included_applications = ["All"]
    }

    users {
      included_groups = local.ca_privileged_group_ids
      excluded_groups = local.ca_excluded_group_ids
    }
  }

  grant_controls {
    operator          = "OR"
    built_in_controls = ["mfa"]
  }
}

resource "azuread_conditional_access_policy" "mfa_all_users" {
  count = local.ca_enabled ? 1 : 0

  display_name = "lz-require-mfa-all-users"
  state        = var.conditional_access_state

  conditions {
    client_app_types = ["all"]

    applications {
      included_applications = ["All"]
    }

    users {
      included_users  = ["All"]
      excluded_groups = local.ca_excluded_group_ids
    }
  }

  grant_controls {
    operator          = "OR"
    built_in_controls = ["mfa"]
  }
}
