output "management_vm" {
  description = "Live proof target and source image, null when disabled."
  value = var.enable_management_vm ? {
    id             = azurerm_linux_virtual_machine.management[0].id
    name           = azurerm_linux_virtual_machine.management[0].name
    resource_group = azurerm_resource_group.compute[0].name
    image_id       = azurerm_linux_virtual_machine.management[0].source_image_id
  } : null
}
