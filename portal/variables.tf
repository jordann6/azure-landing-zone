variable "project" {
  type    = string
  default = "alz"
}

variable "owner" {
  type    = string
  default = "jordann6"
}

variable "cost_center" {
  type    = string
  default = "platform"
}

# Regions are chosen per tier by what the subscription can actually provision
# (checked 2026-10-03): Container Apps had no capacity in centralus, and Azure
# SQL is restricted for this subscription in eastus, eastus2, and northcentralus.
# All must be in the base allowed_locations list.
variable "shared_location" {
  type        = string
  default     = "centralus"
  description = "Region for shared, non-regional services: resource groups for edge and data, Application Insights, API Management, Logic App, app identity, and the registry."
}

variable "primary_location" {
  type        = string
  default     = "westus2"
  description = "App tier, primary region (Front Door priority 1)."
}

variable "secondary_location" {
  type        = string
  default     = "eastus2"
  description = "App tier, secondary region (Front Door priority 2)."
}

variable "sql_primary_location" {
  type        = string
  default     = "centralus"
  description = "Data tier, primary SQL server region."
}

variable "sql_secondary_location" {
  type        = string
  default     = "westus2"
  description = "Data tier, failover-group partner region."
}

variable "app_image" {
  type        = string
  default     = "mcr.microsoft.com/k8se/quickstart:latest"
  description = "Container image for the portal app. Starts on the Microsoft quickstart image; set to the ACR image after scripts/portal-build-image.sh."
}

variable "sql_sku" {
  type        = string
  default     = "GP_S_Gen5_1"
  description = "Azure SQL Database SKU. General Purpose serverless, 1 vCore max."
}

variable "alert_email" {
  type        = string
  default     = "you@example.com"
  description = "APIM publisher email."
}

variable "waf_mode" {
  type        = string
  default     = "Prevention"
  description = "Front Door WAF mode: Prevention blocks, Detection only logs."
}

variable "enable_apim" {
  type        = bool
  default     = true
  description = "Deploy API Management (Consumption) as the partner API facade."
}

variable "enable_external_id" {
  type        = bool
  default     = true
  description = "Create an Entra External ID tenant for member sign-in. App registration and user flow are created by scripts/portal-external-id.ps1."
}

variable "external_id_client_id" {
  type        = string
  default     = ""
  description = "Client ID of the member-portal app registration in the External ID tenant (printed by scripts/portal-external-id.ps1). Empty disables sign-in in the app."
}

variable "availability_test_locations" {
  type        = list(string)
  default     = ["us-tx-sn1-azr", "us-il-ch1-azr", "us-va-ash-azr", "us-ca-sjc-azr", "us-fl-mia-edge"]
  description = "Application Insights availability test locations (South Central, North Central, East, West, Central US)."
}
