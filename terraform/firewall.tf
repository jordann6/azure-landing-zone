# ── FortiGate-VM hub firewall (opt-in) ───────────────────────────────────────
# Enterprises route spoke egress through a network virtual appliance in the hub.
# This deploys a Fortinet FortiGate-VM into dedicated NVA subnets and forces
# every spoke workload subnet's default route through its trust interface, so
# all east-west and north-south traffic is inspected at one chokepoint.
#
# Note on placement: a third-party NVA cannot live in AzureFirewallSubnet, which
# is reserved for the Azure Firewall managed service. The FortiGate gets its own
# untrust/trust subnets, mirroring the Bastion-subnet correction elsewhere in
# this portfolio.
#
# Gated on enable_fortigate (default false) so the landing zone still applies
# cheaply as a pure governance demo.

locals {
  fortigate_enabled = var.enable_fortigate
  fw_count          = local.fortigate_enabled ? 1 : 0
}

# --- NVA subnets in the hub ---
resource "azurerm_subnet" "fw_untrust" {
  # checkov:skip=CKV2_AZURE_31:NVA data-plane subnet for the opt-in FortiGate
  # (off by default). A blanket NSG here would break the appliance's own traffic
  # steering; the FortiGate enforces its policy in place of a subnet NSG.
  count                = local.fw_count
  name                 = "snet-fw-untrust"
  resource_group_name  = azurerm_resource_group.hub.name
  virtual_network_name = azurerm_virtual_network.hub.name
  address_prefixes     = ["10.0.4.0/24"]
}

resource "azurerm_subnet" "fw_trust" {
  # checkov:skip=CKV2_AZURE_31:NVA data-plane subnet for the opt-in FortiGate
  # (off by default); the appliance enforces policy in place of a subnet NSG.
  count                = local.fw_count
  name                 = "snet-fw-trust"
  resource_group_name  = azurerm_resource_group.hub.name
  virtual_network_name = azurerm_virtual_network.hub.name
  address_prefixes     = ["10.0.5.0/24"]
}

# --- Public IP on the untrust (internet-facing) interface ---
resource "azurerm_public_ip" "fw_untrust" {
  count               = local.fw_count
  name                = "pip-${var.project}-fgt-untrust"
  location            = azurerm_resource_group.hub.location
  resource_group_name = azurerm_resource_group.hub.name
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = local.tags
}

# --- NICs: port1 untrust (public), port2 trust (internal next hop) ---
resource "azurerm_network_interface" "fw_untrust" {
  # checkov:skip=CKV_AZURE_119:The untrust interface is deliberately the
  # internet-facing edge of the opt-in FortiGate NVA; a public IP here is the
  # design, not a leak.
  count                 = local.fw_count
  name                  = "nic-${var.project}-fgt-port1"
  location              = azurerm_resource_group.hub.location
  resource_group_name   = azurerm_resource_group.hub.name
  ip_forwarding_enabled = true
  tags                  = local.tags

  ip_configuration {
    name                          = "port1"
    subnet_id                     = azurerm_subnet.fw_untrust[0].id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.fw_untrust[0].id
  }
}

resource "azurerm_network_interface" "fw_trust" {
  count                 = local.fw_count
  name                  = "nic-${var.project}-fgt-port2"
  location              = azurerm_resource_group.hub.location
  resource_group_name   = azurerm_resource_group.hub.name
  ip_forwarding_enabled = true
  tags                  = local.tags

  ip_configuration {
    name                          = "port2"
    subnet_id                     = azurerm_subnet.fw_trust[0].id
    private_ip_address_allocation = "Static"
    private_ip_address            = var.fortigate_trust_ip
  }
}

# --- FortiGate-VM ---
# Marketplace image. Accept terms once per subscription before applying:
#   az vm image terms accept --publisher fortinet \
#     --offer fortinet_fortigate-vm_v5 --plan <fortigate_image_sku>
resource "azurerm_virtual_machine" "fortigate" {
  # checkov:skip=CKV2_AZURE_12:The FortiGate is a stateless network appliance
  # (opt-in, off by default); its config lives on the data disk and is rebuilt
  # from IaC, so Azure Backup of the VM is not the recovery model.
  # checkov:skip=CKV2_AZURE_10:Antimalware does not apply to a FortiGate firewall
  # appliance image.
  count                        = local.fw_count
  name                         = "vm-${var.project}-fortigate"
  location                     = azurerm_resource_group.hub.location
  resource_group_name          = azurerm_resource_group.hub.name
  vm_size                      = var.fortigate_vm_size
  primary_network_interface_id = azurerm_network_interface.fw_untrust[0].id

  network_interface_ids = [
    azurerm_network_interface.fw_untrust[0].id,
    azurerm_network_interface.fw_trust[0].id,
  ]

  plan {
    name      = var.fortigate_image_sku
    publisher = "fortinet"
    product   = "fortinet_fortigate-vm_v5"
  }

  storage_image_reference {
    publisher = "fortinet"
    offer     = "fortinet_fortigate-vm_v5"
    sku       = var.fortigate_image_sku
    version   = "latest"
  }

  storage_os_disk {
    name              = "osdisk-${var.project}-fortigate"
    caching           = "ReadWrite"
    create_option     = "FromImage"
    managed_disk_type = "Standard_LRS"
  }

  # FortiGate keeps its config/logs on a second data disk.
  storage_data_disk {
    name              = "datadisk-${var.project}-fortigate"
    lun               = 0
    create_option     = "Empty"
    disk_size_gb      = 30
    managed_disk_type = "Standard_LRS"
  }

  os_profile {
    computer_name  = "fortigate"
    admin_username = var.fortigate_admin_username
    admin_password = var.fortigate_admin_password
  }

  os_profile_linux_config {
    disable_password_authentication = false
  }

  delete_os_disk_on_termination    = true
  delete_data_disks_on_termination = true
  tags                             = local.tags

  lifecycle {
    precondition {
      condition     = var.fortigate_admin_password != null && var.fortigate_admin_password != ""
      error_message = "Set fortigate_admin_password when enable_fortigate = true."
    }
  }
}

# --- Force each spoke's workload subnet egress through the FortiGate ---
resource "azurerm_route_table" "fgt_egress" {
  count               = local.fw_count
  name                = "rt-${var.project}-fgt-egress"
  location            = azurerm_resource_group.hub.location
  resource_group_name = azurerm_resource_group.hub.name
  tags                = local.tags

  route {
    name                   = "default-via-fortigate"
    address_prefix         = "0.0.0.0/0"
    next_hop_type          = "VirtualAppliance"
    next_hop_in_ip_address = var.fortigate_trust_ip
  }
}

resource "azurerm_subnet_route_table_association" "fgt_spoke" {
  for_each = local.fw_count == 1 ? local.spoke_workload_subnet_ids : {}

  subnet_id      = each.value
  route_table_id = azurerm_route_table.fgt_egress[0].id
}
