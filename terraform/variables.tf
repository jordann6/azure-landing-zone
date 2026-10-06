variable "location" {
  type    = string
  default = "centralus"
}

variable "project" {
  type    = string
  default = "alz"
}

variable "allowed_locations" {
  type        = list(string)
  default     = ["centralus", "eastus2", "westus2", "global"]
  description = "Regions the allowed-locations Deny policy permits."
}

variable "allowed_vm_skus" {
  type        = list(string)
  default     = ["Standard_B2s", "Standard_B2s_v2", "Standard_D2s_v3", "Standard_D2s_v5"]
  description = "Permitted standalone VM sizes. Keep workload aks_node_vm_size in this list for consistent compute sizing."
  validation {
    condition     = length(var.allowed_vm_skus) > 0
    error_message = "At least one approved VM size is required."
  }
}

variable "enable_image_build" {
  type        = bool
  default     = false
  description = "Create the temporary Packer resource group and scoped policy exemptions. Turn off after the build."
}

variable "image_build_exemption_expires_on" {
  type        = string
  default     = null
  description = "Fixed UTC RFC3339 expiry, at most four hours ahead when enabling a build."
  validation {
    condition     = var.image_build_exemption_expires_on == null ? true : can(formatdate("YYYY", var.image_build_exemption_expires_on))
    error_message = "Provide an RFC3339 UTC expiry."
  }
}

# --- Governance / cost ---
variable "budget_amount" {
  type        = number
  default     = 20
  description = "Monthly subscription budget in USD."
}

variable "alert_email" {
  type        = string
  description = "Budget-alert recipient. No default, so no address is committed; set it in the gitignored terraform.tfvars."

  validation {
    condition     = can(regex("^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$", var.alert_email))
    error_message = "alert_email must be an email address."
  }
}

variable "firewall_deny_alert_threshold" {
  type        = number
  default     = 50
  description = "Firewall denies per 15 minutes above which the deny-spike alert fires."
}

variable "platform_managed_resource_groups" {
  type        = list(string)
  default     = ["rg-alz-portal-cus-aca-infra", "rg-alz-portal-eus2-aca-infra"]
  description = "Resource groups created by Azure services for their own infrastructure (Container Apps environments in portal/). Excluded from the tag-required policies only."
}

# --- Feature flags (default true in code; a gitignored terraform.tfvars turns
# the hourly-billed ones off for a cheap governance-only apply, mirroring the
# AWS reduced-footprint pattern). ---
variable "enable_firewall" {
  type        = bool
  default     = true
  description = "Deploy Azure Firewall in the hub and force spoke egress through it. Hourly cost (~$1.25/hr). Mutually exclusive with enable_fortigate."
}

variable "enable_bastion" {
  type        = bool
  default     = true
  description = "Deploy Azure Bastion for the only admin path (no public SSH/RDP). Hourly cost (~$0.19/hr)."
}

variable "enable_private_endpoints" {
  type        = bool
  default     = true
  description = "Deploy Private DNS zones and a private endpoint for the Key Vault. Small hourly cost per endpoint."
}

variable "enable_defender_standard" {
  type        = bool
  default     = false
  description = "Turn on paid Microsoft Defender for Cloud plans. Off by default: the free foundational CSPM already renders the CIS assessment. Paid plans bill per resource."
}

variable "defender_servers_subplan" {
  type        = string
  default     = "P1"
  description = "Defender for Servers sub-plan used when enable_defender_standard is on. P1 is about $5 per server per month, P2 about $15 (see docs/adr/0004-detection-tier.md)."

  validation {
    condition     = contains(["P1", "P2"], var.defender_servers_subplan)
    error_message = "defender_servers_subplan must be P1 or P2."
  }
}

variable "enable_flow_logs" {
  type        = bool
  default     = false
  description = "VNet flow logs for the hub (and the prod VNet, via workload/) with traffic analytics in the central workspace. Off by default: storage and analytics bill by volume (small at demo traffic)."
}

variable "flow_log_retention_days" {
  type        = number
  default     = 7
  description = "Days the raw flow logs stay in the storage account. Traffic analytics rows follow the workspace retention."

  validation {
    condition     = var.flow_log_retention_days >= 1 && var.flow_log_retention_days <= 365
    error_message = "flow_log_retention_days must be between 1 and 365."
  }
}

variable "create_entra_identity" {
  type        = bool
  default     = true
  description = "Create Entra ID persona groups, MG-scope RBAC, and PIM eligibility. Needs tenant Graph permissions (and P2 for PIM). Set false where the demo tenant lacks them."
}

variable "enable_pim" {
  type        = bool
  default     = true
  description = "Create PIM eligible (JIT) role assignments for the prod-write persona. Requires Entra ID P2. Only takes effect when create_entra_identity is true."
}

variable "kv_admin_object_id" {
  type        = string
  default     = ""
  description = "Object ID granted Key Vault Crypto Officer so the CMK can be created. Empty falls back to the deploying principal."
}

variable "deployer_ip_cidrs" {
  type        = list(string)
  default     = []
  description = "Public IP CIDRs allowed through the Key Vault firewall so the deploying workstation can create the CMK on first apply. Set this to your own IP (e.g. [\"203.0.113.4/32\"]) before applying; the vault default action is Deny."
}

# --- FortiGate-VM hub firewall (opt-in alternative to Azure Firewall) ---
variable "enable_fortigate" {
  type        = bool
  default     = false
  description = "Deploy a FortiGate-VM NVA instead of Azure Firewall. Mutually exclusive with enable_firewall. Off by default."
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
