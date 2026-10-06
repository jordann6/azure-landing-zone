data "azurerm_shared_image_versions" "hardened" {
  count               = var.enable_management_vm ? 1 : 0
  gallery_name        = local.gallery.name
  image_name          = local.gallery.image_name
  resource_group_name = local.gallery.resource_group_name
}

locals {
  eligible_versions = var.enable_management_vm ? [
    for image in data.azurerm_shared_image_versions.hardened[0].images : image
    if !image.exclude_from_latest
  ] : []
}

data "azurerm_shared_image_version" "latest" {
  count                   = length(local.eligible_versions) > 0 ? 1 : 0
  name                    = "latest"
  gallery_name            = local.gallery.name
  image_name              = local.gallery.image_name
  resource_group_name     = local.gallery.resource_group_name
  sort_versions_by_semver = true
}

resource "azurerm_resource_group" "compute" {
  count    = var.enable_management_vm ? 1 : 0
  name     = "rg-${local.gallery.project}-compute"
  location = local.gallery.location
  tags     = local.tags
}

resource "azurerm_network_interface" "management" {
  count               = var.enable_management_vm ? 1 : 0
  name                = "nic-${local.gallery.project}-mgmt"
  location            = local.gallery.location
  resource_group_name = azurerm_resource_group.compute[0].name
  tags                = local.tags
  ip_configuration {
    name                          = "private"
    subnet_id                     = local.gallery.management_subnet_id
    private_ip_address_allocation = "Dynamic"
  }
}

resource "azurerm_linux_virtual_machine" "management" {
  count                           = var.enable_management_vm ? 1 : 0
  name                            = "vm-${local.gallery.project}-mgmt"
  resource_group_name             = azurerm_resource_group.compute[0].name
  location                        = local.gallery.location
  size                            = var.vm_size
  admin_username                  = "lzadmin"
  network_interface_ids           = [azurerm_network_interface.management[0].id]
  source_image_id                 = try(data.azurerm_shared_image_version.latest[0].id, null)
  disable_password_authentication = true
  encryption_at_host_enabled      = true
  secure_boot_enabled             = true
  vtpm_enabled                    = true
  provision_vm_agent              = true
  patch_mode                      = "AutomaticByPlatform"
  patch_assessment_mode           = "AutomaticByPlatform"
  # Custom images use customer-managed schedules, not automatic guest patching.
  bypass_platform_safety_checks_on_user_schedule_enabled = true
  tags                                                   = local.tags

  # checkov:skip=CKV_AZURE_50:Azure Run Command and policy guest configuration require the Azure VM agent; no third-party VM extension is installed.

  admin_ssh_key {
    username   = "lzadmin"
    public_key = var.ssh_public_key
  }
  identity { type = "SystemAssigned" }
  os_disk {
    name                 = "disk-${local.gallery.project}-mgmt-os"
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }
  # checkov:skip=CKV_AZURE_1:This short-lived proof VM uses platform-managed disk keys plus host encryption. Adding a DES/CMK dependency is deferred; no application data is stored.
  # checkov:skip=CKV_AZURE_178:The root policy requires SSH key-only access, and deployment generates a unique key that is supplied through a mode-0600 temporary tfvars file; password authentication is disabled.

  lifecycle {
    precondition {
      condition     = length(local.eligible_versions) > 0
      error_message = "No eligible gallery image version exists; run make build-image first."
    }
    precondition {
      condition     = startswith(var.ssh_public_key, "ssh-")
      error_message = "Provide an SSH public key; never pass the private key."
    }
  }
}

resource "azurerm_maintenance_configuration" "security" {
  count                    = var.enable_management_vm ? 1 : 0
  name                     = "mc-${local.gallery.project}-security"
  resource_group_name      = azurerm_resource_group.compute[0].name
  location                 = local.gallery.location
  scope                    = "InGuestPatch"
  in_guest_user_patch_mode = "User"
  tags                     = local.tags
  window {
    start_date_time = "2026-10-11 02:00"
    time_zone       = "Central Standard Time"
    duration        = "03:00"
    recur_every     = "Week Sunday"
  }
  install_patches {
    reboot = "IfRequired"
    linux { classifications_to_include = ["Critical", "Security"] }
  }
}

resource "azurerm_maintenance_assignment_virtual_machine" "management" {
  count                        = var.enable_management_vm ? 1 : 0
  location                     = local.gallery.location
  maintenance_configuration_id = azurerm_maintenance_configuration.security[0].id
  virtual_machine_id           = azurerm_linux_virtual_machine.management[0].id
}
