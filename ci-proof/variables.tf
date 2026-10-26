variable "resource_group_name" {
  type        = string
  default     = "rg-alz-ci"
  description = "Operator-owned resource group from bootstrap/. The CI apply identity can write here and nowhere else."
}

variable "address_space" {
  type        = list(string)
  default     = ["10.250.0.0/24"]
  description = "Isolated range, not peered to the hub, so nothing CI creates here can reach the landing zone."
}
