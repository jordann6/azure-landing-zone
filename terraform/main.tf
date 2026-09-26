locals {
  tags = {
    project             = "azure-landing-zone"
    owner               = "jordann6"
    managed_by          = "terraform"
    cost_center         = "platform"
    environment         = "shared"
    data_classification = "internal"
  }
}

data "azurerm_client_config" "current" {}
data "azurerm_subscription" "current" {}

# ── Management group hierarchy ────────────────────────────────────────────────
# Root
#  ├── Platform      (management, connectivity, identity: single-sub demo uses RGs)
#  ├── Workloads
#  │     ├── Dev
#  │     ├── Test
#  │     └── Prod     (governed more strictly by inheritance + extra Prod denies)
#  └── Sandbox
#
# Single-subscription constraint: there is no EA/MCA to vend a subscription per
# tier, so the tiers are management groups plus resource groups. The intended
# subscription-per-tier design is documented in docs/access-model.md.

resource "azurerm_management_group" "root" {
  display_name = "jordann6"
  name         = "mg-jordann6"
}

resource "azurerm_management_group" "platform" {
  display_name               = "Platform"
  name                       = "mg-jordann6-platform"
  parent_management_group_id = azurerm_management_group.root.id
}

resource "azurerm_management_group" "workloads" {
  display_name               = "Workloads"
  name                       = "mg-jordann6-workloads"
  parent_management_group_id = azurerm_management_group.root.id
}

resource "azurerm_management_group" "dev" {
  display_name               = "Dev"
  name                       = "mg-jordann6-dev"
  parent_management_group_id = azurerm_management_group.workloads.id
}

resource "azurerm_management_group" "test" {
  display_name               = "Test"
  name                       = "mg-jordann6-test"
  parent_management_group_id = azurerm_management_group.workloads.id
}

resource "azurerm_management_group" "prod" {
  display_name               = "Prod"
  name                       = "mg-jordann6-prod"
  parent_management_group_id = azurerm_management_group.workloads.id
}

resource "azurerm_management_group" "sandbox" {
  display_name               = "Sandbox"
  name                       = "mg-jordann6-sandbox"
  parent_management_group_id = azurerm_management_group.root.id
}

# Move the subscription into the Workloads management group so the policies
# assigned there (and inherited from the root) take effect on all resources.
resource "azurerm_management_group_subscription_association" "workloads" {
  management_group_id = azurerm_management_group.workloads.id
  subscription_id     = data.azurerm_subscription.current.id
}
