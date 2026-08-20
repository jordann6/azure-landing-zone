variable "location" {
  type    = string
  default = "eastus"
}

variable "project" {
  type    = string
  default = "alz"
}

# --- FortiGate-VM hub firewall (opt-in) ---
variable "enable_fortigate" {
  type        = bool
  default     = false
  description = "Deploy a FortiGate-VM in the hub and route spoke egress through it. Adds real cost, so it is off by default."
}

variable "fortigate_vm_size" {
  type        = string
  default     = "Standard_F2s_v2"
  description = "FortiGate-VM supports 2+ vCPU. F2s_v2 is the smallest practical size."
}

variable "fortigate_image_sku" {
  type        = string
  default     = "fortinet_fg-vm"
  description = "Marketplace SKU for fortinet/fortinet_fortigate-vm_v5. fortinet_fg-vm is BYOL; use a *_payg_* SKU for pay-as-you-go. Accept terms first: az vm image terms accept."
}

variable "fortigate_trust_ip" {
  type        = string
  default     = "10.0.5.4"
  description = "Static private IP of the FortiGate trust (port2) interface. Next hop for spoke default routes."
}

variable "fortigate_admin_username" {
  type    = string
  default = "fgtadmin"
}

variable "fortigate_admin_password" {
  type        = string
  default     = null
  sensitive   = true
  description = "Bootstrap admin password for the FortiGate. Required only when enable_fortigate = true."
}
