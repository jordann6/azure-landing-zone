variable "enable_management_vm" {
  type        = bool
  default     = false
  description = "Enable the hourly management VM for a supervised compute session. make deploy-compute enables it."
}

variable "vm_size" {
  type        = string
  default     = "Standard_B2s"
  description = "Small host-encryption-capable VM size permitted by the root policy."
}

variable "ssh_public_key" {
  type        = string
  default     = ""
  description = "Public SSH key only. No public IP or inbound SSH rule is created; run-command is the demo access path."
}
