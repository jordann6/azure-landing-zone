variable "name" {
  type        = string
  description = "Spoke name (e.g. platform, sandbox). Used in resource names."
}

variable "project" {
  type        = string
  description = "Short project prefix used in resource names."
}

variable "location" {
  type        = string
  description = "Azure region for all spoke resources."
}

variable "address_space" {
  type        = list(string)
  description = "CIDR block for the spoke VNet (e.g. [\"10.1.0.0/16\"])."
}

variable "workload_subnet_prefix" {
  type        = string
  description = "CIDR prefix for the spoke's workload subnet."
}

variable "hub_vnet_id" {
  type        = string
  description = "Resource ID of the hub VNet for the hub-to-spoke peering."
}

variable "hub_vnet_name" {
  type        = string
  description = "Name of the hub VNet (needed for the hub-side peering resource)."
}

variable "hub_resource_group_name" {
  type        = string
  description = "Resource group that contains the hub VNet."
}

variable "tags" {
  type        = map(string)
  default     = {}
  description = "Tags applied to all resources in the spoke."
}
