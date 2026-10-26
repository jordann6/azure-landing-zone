variable "location" {
  description = "Region for the state backend. Matches the landing zone's primary region."
  type        = string
  default     = "centralus"
}

variable "storage_account_name" {
  description = "Globally unique state storage account name. Every root's backend block hardcodes it, so change them together."
  type        = string
  default     = "stalztfstatejn"
}

variable "key_vault_name" {
  description = "Globally unique name for the vault holding the state encryption key."
  type        = string
  default     = "kv-alz-tfstate-jn"
}

variable "deployer_ip_cidrs" {
  description = "Public IPs (CIDR) allowed through the Key Vault firewall, and through the storage firewall when network_default_action is Deny. The deployer needs Key Vault access to create the key on first apply."
  type        = list(string)
  default     = []
}

variable "network_default_action" {
  description = "Storage firewall default. Allow relies on Entra-only auth plus RBAC as the perimeter; Deny limits access to deployer_ip_cidrs (see docs/adr/0001-dedicated-state-backend.md)."
  type        = string
  default     = "Allow"

  validation {
    condition     = contains(["Allow", "Deny"], var.network_default_action)
    error_message = "network_default_action must be Allow or Deny."
  }
}

variable "github_oidc_subject_prefix" {
  description = "Subject prefix GitHub puts on this repo's OIDC tokens. GitHub now issues the immutable form, repo:OWNER@OWNER_ID/REPO@REPO_ID, so a deleted and recreated repo with the same name cannot inherit the trust. Read it with: gh api repos/OWNER/REPO/actions/oidc/customization/sub"
  type        = string
  default     = "repo:jordann6@196278615/azure-landing-zone@1407358203"
}
