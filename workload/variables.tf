variable "location" {
  description = "Primary region (must match the base landing zone)."
  type        = string
  default     = "centralus"
}

variable "project" {
  description = "Naming prefix, matches the base landing zone."
  type        = string
  default     = "alz"
}

variable "resource_group_name" {
  description = "Override for the prod workload resource group name (default rg-<project>-prod-workload). Use it to deploy in another region while the old group still holds a soft-deleted backup instance; keep the rg-<project>- prefix so verify-teardown.py covers it."
  type        = string
  default     = null
}

variable "owner" {
  type    = string
  default = "jordann6"
}

variable "cost_center" {
  type    = string
  default = "platform"
}

# ── Prod-tier network (owned by this workload root, mirrors AWS vpc.tf) ────────
variable "prod_cidr" {
  description = "Prod workload VNet CIDR (portfolio address plan)."
  type        = string
  default     = "10.3.0.0/16"
}

variable "aks_subnet_prefix" {
  description = "Subnet for AKS nodes."
  type        = string
  default     = "10.3.0.0/22"
}

variable "data_subnet_prefix" {
  description = "Delegated subnet for the PostgreSQL flexible server."
  type        = string
  default     = "10.3.8.0/24"
}

variable "app_subnet_prefix" {
  description = "Application tier subnet."
  type        = string
  default     = "10.3.9.0/24"
}

variable "pe_subnet_prefix" {
  description = "Private-endpoint subnet (ACR, Key Vault)."
  type        = string
  default     = "10.3.10.0/24"
}

variable "apiserver_subnet_prefix" {
  description = "Delegated subnet for AKS API Server VNet Integration (required so a private control plane can reach the etcd CMK over the private Key Vault)."
  type        = string
  default     = "10.3.11.0/28"
}

# AKS overlay ranges, must not overlap the VNet address space.
variable "aks_service_cidr" {
  description = "Kubernetes service CIDR (non-overlapping with the VNet)."
  type        = string
  default     = "172.16.0.0/16"
}

variable "aks_dns_service_ip" {
  description = "Cluster DNS service IP inside aks_service_cidr."
  type        = string
  default     = "172.16.0.10"
}

variable "aks_pod_cidr" {
  description = "Overlay pod CIDR (internal to the cluster)."
  type        = string
  default     = "10.244.0.0/16"
}

# ── AKS ───────────────────────────────────────────────────────────────────────
variable "kubernetes_version" {
  description = "AKS Kubernetes version."
  type        = string
  default     = "1.30"
}

variable "aks_node_vm_size" {
  description = "Node pool VM size (small, timed demo)."
  type        = string
  default     = "Standard_D2s_v3"
}

variable "aks_node_count" {
  description = "Node pool node count."
  type        = number
  default     = 2
}

# ── Data tier ─────────────────────────────────────────────────────────────────
variable "pg_version" {
  description = "PostgreSQL flexible server major version."
  type        = string
  default     = "16"
}

variable "pg_sku" {
  description = "PostgreSQL flexible server SKU (small, timed demo)."
  type        = string
  default     = "GP_Standard_D2s_v3"
}

variable "pg_storage_mb" {
  description = "PostgreSQL storage in MB."
  type        = number
  default     = 32768
}

# ── Deployer access so CMK keys can be created on first apply ─────────────────
variable "deployer_ip_cidrs" {
  description = "Workstation public IP(s)/32 permitted to the workload Key Vault + ACR firewall for the CMK/setup path."
  type        = list(string)
  default     = []
}

# ── Backup (WORM) ─────────────────────────────────────────────────────────────
variable "backup_retention_days" {
  description = "Backup vault retention (immutability floor)."
  type        = number
  default     = 7
}

variable "backup_immutability_locked" {
  description = "false keeps the vault immutability policy unlocked so the demo can be torn down; production locks it for irreversible WORM. Mirrors the AWS Vault Lock changeable_for_days knob."
  type        = bool
  default     = false
}
