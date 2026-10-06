resource "azurerm_resource_group" "images" {
  name     = "rg-${var.project}-images"
  location = var.location
  tags     = merge(local.tags, { environment = "platform" })
}

resource "azurerm_shared_image_gallery" "hardened" {
  name                = local.compute_gallery_name
  resource_group_name = azurerm_resource_group.images.name
  location            = var.location
  description         = "Hardened management images for this landing zone"
  tags                = azurerm_resource_group.images.tags
}

resource "azurerm_shared_image" "ubuntu" {
  name                     = "hardened-ubuntu-2204"
  gallery_name             = azurerm_shared_image_gallery.hardened.name
  resource_group_name      = azurerm_resource_group.images.name
  location                 = var.location
  os_type                  = "Linux"
  hyper_v_generation       = "V2"
  trusted_launch_supported = true
  identifier {
    publisher = "landing-zone"
    offer     = "cis-baseline"
    sku       = "ubuntu-2204"
  }
  tags = azurerm_resource_group.images.tags
}

# The build resources and both narrow exemptions exist only for a timed bake.
# Approved-image enforcement also needs an exemption to bootstrap a stock image.
resource "azurerm_resource_group" "image_build" {
  count    = var.enable_image_build ? 1 : 0
  name     = "rg-${var.project}-image-build"
  location = var.location
  tags     = merge(local.tags, { environment = "image-build" })
}

resource "azurerm_resource_group_policy_exemption" "image_build" {
  for_each = var.enable_image_build ? {
    public_ip = azurerm_management_group_policy_assignment.deny_public_ip.id
    image     = azurerm_management_group_policy_assignment.approved_vm_images.id
  } : {}
  name                 = "packer-${each.key}"
  resource_group_id    = azurerm_resource_group.image_build[0].id
  policy_assignment_id = each.value
  exemption_category   = "Waiver"
  expires_on           = var.image_build_exemption_expires_on
  description          = "Timed Packer bootstrap only: public SSH restricted to the workstation; stock image is hardened before publishing. Remove after bake."

  lifecycle {
    precondition {
      condition = var.image_build_exemption_expires_on == null ? false : (
        timecmp(var.image_build_exemption_expires_on, timestamp()) > 0 &&
        timecmp(var.image_build_exemption_expires_on, timeadd(timestamp(), "4h")) <= 0
      )
      error_message = "A future fixed expiry at most four hours ahead is required for image-build exemptions."
    }
  }
}
