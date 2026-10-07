variable "project" {
  description = "Naming prefix, matches the base landing zone."
  type        = string
  default     = "alz"
}

variable "location" {
  description = "Region for the scanner identity (must match the base landing zone)."
  type        = string
  default     = "centralus"
}

variable "enable_control_secret" {
  description = "Seed one inert secret with no expiry in the CMK vault as the scanner positive control. The LZ vaults hold almost nothing between deploys, so without it the scanner has nothing to flag. Grants the deployer Key Vault Secrets Officer on that vault while this root exists."
  type        = bool
  default     = true
}

variable "near_expiry_alert_enabled" {
  description = "Alert when Key Vault reports a secret, key or certificate near expiry or expired."
  type        = bool
  default     = true
}
