variable "project" {
  description = "Naming prefix, matches the base landing zone."
  type        = string
  default     = "alz"
}

variable "location" {
  description = "Region for the findings export and log alerts (must match the base landing zone)."
  type        = string
  default     = "centralus"
}

variable "enable_findings_export" {
  description = "Stream Defender for Cloud alerts and high-severity recommendations into the central workspace and alert on HIGH findings. Export is free; ingestion is cents at demo volume."
  type        = bool
  default     = true
}
