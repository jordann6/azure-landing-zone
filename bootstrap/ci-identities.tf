# GitHub Actions identities for the shared platform-guardrails workflows.
#
# Two user-assigned identities, each reached only through a GitHub OIDC
# federated credential. No client secret exists anywhere.
#
#   plan   Trusts pull requests and main. Reader on the subscription, so it can
#          refresh any root for plans, drift and the TTL guard. It cannot write
#          to Azure at all.
#   apply  Trusts the prod-apply and destroy environments only, so a run has to
#          clear a required reviewer before it can mint a token. Contributor on
#          rg-alz-ci and nothing else.
#
# CI never applies governance or this root. Both identities, their federated
# credentials, their role assignments and rg-alz-ci live here, and this root is
# operator-applied, so CI can never rewrite its own trust. Contributor cannot
# create role assignments, and the apply identity holds nothing above rg-alz-ci.
#
# State: both hold Storage Blob Data Contributor on the tfstate container with an
# ABAC condition. Reads are open (remote state, refresh), but write, delete and
# lease (a lease is a blob write) are limited to the CI root's state blob. A PR
# that plans hostile Terraform cannot overwrite another root's state.

locals {
  github_oidc_issuer   = "https://token.actions.githubusercontent.com"
  github_oidc_audience = "api://AzureADTokenExchange"

  # The only state blob CI may write. Matches ci-proof/providers.tf.
  ci_state_key = "azure-landing-zone/ci-proof.terraform.tfstate"

  tfstate_container_scope = "${azurerm_storage_account.state.id}/blobServices/default/containers/${azurerm_storage_container.tfstate.name}"

  ci_state_write_condition = <<-EOT
    (
     (
      !(ActionMatches{'Microsoft.Storage/storageAccounts/blobServices/containers/blobs/write'})
      AND
      !(ActionMatches{'Microsoft.Storage/storageAccounts/blobServices/containers/blobs/add/action'})
      AND
      !(ActionMatches{'Microsoft.Storage/storageAccounts/blobServices/containers/blobs/delete'})
      AND
      !(ActionMatches{'Microsoft.Storage/storageAccounts/blobServices/containers/blobs/move/action'})
     )
     OR
     (
      @Resource[Microsoft.Storage/storageAccounts/blobServices/containers/blobs:path] StringEquals '${local.ci_state_key}'
     )
    )
  EOT
}

data "azurerm_subscription" "current" {}

# The one resource group CI may write to. Operator-owned and standing (empty
# between sessions, so free); ci-proof creates and destroys what goes inside.
resource "azurerm_resource_group" "ci" {
  name     = "rg-alz-ci"
  location = var.location
  tags     = merge(local.tags, { environment = "ci" })
}

# ── Plan identity (read) ─────────────────────────────────────────────────────

resource "azurerm_user_assigned_identity" "gha_plan" {
  name                = "id-alz-gha-plan"
  location            = azurerm_resource_group.state.location
  resource_group_name = azurerm_resource_group.state.name
  tags                = local.tags
}

# Azure rejects concurrent federated credential writes on one identity, so each
# identity's credentials are chained with depends_on.
resource "azurerm_federated_identity_credential" "gha_plan_pull_request" {
  name                      = "github-pull-request"
  user_assigned_identity_id = azurerm_user_assigned_identity.gha_plan.id
  issuer                    = local.github_oidc_issuer
  audience                  = [local.github_oidc_audience]
  subject                   = "${var.github_oidc_subject_prefix}:pull_request"
}

resource "azurerm_federated_identity_credential" "gha_plan_main" {
  name                      = "github-main"
  user_assigned_identity_id = azurerm_user_assigned_identity.gha_plan.id
  issuer                    = local.github_oidc_issuer
  audience                  = [local.github_oidc_audience]
  subject                   = "${var.github_oidc_subject_prefix}:ref:refs/heads/main"

  depends_on = [azurerm_federated_identity_credential.gha_plan_pull_request]
}

resource "azurerm_role_assignment" "gha_plan_reader" {
  scope                = data.azurerm_subscription.current.id
  role_definition_name = "Reader"
  principal_id         = azurerm_user_assigned_identity.gha_plan.principal_id
  principal_type       = "ServicePrincipal"
}

resource "azurerm_role_assignment" "gha_plan_state" {
  scope                = local.tfstate_container_scope
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azurerm_user_assigned_identity.gha_plan.principal_id
  principal_type       = "ServicePrincipal"
  condition            = local.ci_state_write_condition
  condition_version    = "2.0"
}

# ── Apply identity (write, environment-gated) ────────────────────────────────

resource "azurerm_user_assigned_identity" "gha_apply" {
  name                = "id-alz-gha-apply"
  location            = azurerm_resource_group.state.location
  resource_group_name = azurerm_resource_group.state.name
  tags                = local.tags
}

resource "azurerm_federated_identity_credential" "gha_apply_prod_apply" {
  name                      = "github-env-prod-apply"
  user_assigned_identity_id = azurerm_user_assigned_identity.gha_apply.id
  issuer                    = local.github_oidc_issuer
  audience                  = [local.github_oidc_audience]
  subject                   = "${var.github_oidc_subject_prefix}:environment:prod-apply"
}

resource "azurerm_federated_identity_credential" "gha_apply_destroy" {
  name                      = "github-env-destroy"
  user_assigned_identity_id = azurerm_user_assigned_identity.gha_apply.id
  issuer                    = local.github_oidc_issuer
  audience                  = [local.github_oidc_audience]
  subject                   = "${var.github_oidc_subject_prefix}:environment:destroy"

  depends_on = [azurerm_federated_identity_credential.gha_apply_prod_apply]
}

resource "azurerm_role_assignment" "gha_apply_ci_rg" {
  scope                = azurerm_resource_group.ci.id
  role_definition_name = "Contributor"
  principal_id         = azurerm_user_assigned_identity.gha_apply.principal_id
  principal_type       = "ServicePrincipal"
}

resource "azurerm_role_assignment" "gha_apply_state" {
  scope                = local.tfstate_container_scope
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azurerm_user_assigned_identity.gha_apply.principal_id
  principal_type       = "ServicePrincipal"
  condition            = local.ci_state_write_condition
  condition_version    = "2.0"
}
