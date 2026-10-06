# Compute controls apply at the root management group. Golden-image enforcement
# deliberately excludes VM scale sets so AKS can retain its managed node images.
locals {
  compute_gallery_name = "gal${var.project}"
  compute_gallery_id   = "${data.azurerm_subscription.current.id}/resourceGroups/rg-${var.project}-images/providers/Microsoft.Compute/galleries/${local.compute_gallery_name}"
}

resource "azurerm_policy_definition" "approved_vm_images" {
  name                = "approved-vm-images"
  policy_type         = "Custom"
  mode                = "Indexed"
  display_name        = "Standalone virtual machines must use the landing zone gallery"
  management_group_id = azurerm_management_group.root.id

  parameters = jsonencode({
    galleryId = { type = "String" }
  })
  policy_rule = jsonencode({
    "if" = {
      allOf = [
        { field = "type", equals = "Microsoft.Compute/virtualMachines" },
        {
          anyOf = [
            { field = "Microsoft.Compute/virtualMachines/storageProfile.imageReference.id", exists = "false" },
            {
              field   = "Microsoft.Compute/virtualMachines/storageProfile.imageReference.id"
              notLike = "[concat(parameters('galleryId'), '/images/*')]"
            }
          ]
        }
      ]
    }
    "then" = { effect = "Deny" }
  })
}

resource "azurerm_management_group_policy_assignment" "approved_vm_images" {
  name                 = "approved-vm-images"
  display_name         = "Standalone VMs: approved gallery only"
  management_group_id  = azurerm_management_group.root.id
  policy_definition_id = azurerm_policy_definition.approved_vm_images.id
  parameters           = jsonencode({ galleryId = { value = local.compute_gallery_id } })
  depends_on           = [azurerm_management_group_subscription_association.workloads]
}

data "azurerm_policy_definition" "vm_sizes" {
  display_name = "Allowed virtual machine size SKUs"
}

resource "azurerm_management_group_policy_assignment" "vm_sizes" {
  name                 = "allowed-vm-sizes"
  management_group_id  = azurerm_management_group.root.id
  policy_definition_id = data.azurerm_policy_definition.vm_sizes.id
  parameters           = jsonencode({ listOfAllowedSKUs = { value = var.allowed_vm_skus } })
  depends_on           = [azurerm_management_group_subscription_association.workloads]
}

data "azurerm_policy_definition" "host_encryption" {
  display_name = "Virtual machines and virtual machine scale sets should have encryption at host enabled"
}

resource "azurerm_management_group_policy_assignment" "host_encryption" {
  name                 = "require-host-encryption"
  management_group_id  = azurerm_management_group.root.id
  policy_definition_id = data.azurerm_policy_definition.host_encryption.id
  parameters           = jsonencode({ effect = { value = "Deny" } })
  depends_on           = [azurerm_management_group_subscription_association.workloads]
}

data "azurerm_policy_set_definition" "guest_prerequisites" {
  display_name = "Deploy prerequisites to enable Guest Configuration policies on virtual machines"
}

resource "azurerm_management_group_policy_assignment" "guest_prerequisites" {
  name                 = "guest-config-prereqs"
  management_group_id  = azurerm_management_group.root.id
  policy_definition_id = data.azurerm_policy_set_definition.guest_prerequisites.id
  location             = var.location
  identity { type = "SystemAssigned" }
  depends_on = [azurerm_management_group_subscription_association.workloads]
}

resource "azurerm_role_assignment" "guest_remediation" {
  scope                = azurerm_management_group.root.id
  role_definition_name = "Contributor"
  principal_id         = azurerm_management_group_policy_assignment.guest_prerequisites.identity[0].principal_id
}

data "azurerm_policy_definition" "linux_baseline" {
  display_name = "Linux machines should meet requirements for the Azure compute security baseline"
}

resource "azurerm_management_group_policy_assignment" "linux_baseline" {
  name                 = "linux-compute-baseline"
  management_group_id  = azurerm_management_group.root.id
  policy_definition_id = data.azurerm_policy_definition.linux_baseline.id
  parameters = jsonencode({
    effect             = { value = "AuditIfNotExists" }
    IncludeArcMachines = { value = "false" }
  })
  depends_on = [azurerm_management_group_subscription_association.workloads]
}

data "azurerm_policy_definition" "periodic_assessment" {
  display_name = "Configure periodic checking for missing system updates on azure virtual machines"
}

# The built-in defaults to Windows. Assign explicitly for each OS so Linux is
# covered too, and grant its documented Contributor remediation role.
resource "azurerm_management_group_policy_assignment" "periodic_assessment" {
  for_each             = toset(["Linux", "Windows"])
  name                 = "assess-${lower(each.value)}-updates"
  management_group_id  = azurerm_management_group.root.id
  policy_definition_id = data.azurerm_policy_definition.periodic_assessment.id
  location             = var.location
  parameters = jsonencode({
    osType         = { value = each.value }
    assessmentMode = { value = "AutomaticByPlatform" }
  })
  identity { type = "SystemAssigned" }
  depends_on = [azurerm_management_group_subscription_association.workloads]
}

resource "azurerm_role_assignment" "assessment_remediation" {
  for_each             = azurerm_management_group_policy_assignment.periodic_assessment
  scope                = azurerm_management_group.root.id
  role_definition_name = "Contributor"
  principal_id         = each.value.identity[0].principal_id
}

data "azurerm_policy_definition" "assessment_audit" {
  display_name = "Machines should be configured to periodically check for missing system updates"
}

resource "azurerm_management_group_policy_assignment" "assessment_audit" {
  name                 = "audit-update-assessment"
  management_group_id  = azurerm_management_group.root.id
  policy_definition_id = data.azurerm_policy_definition.assessment_audit.id
  parameters           = jsonencode({ effect = { value = "Audit" } })
  depends_on           = [azurerm_management_group_subscription_association.workloads]
}
