# Copy to terraform.tfvars (gitignored) and edit. The prod workload paved road:
# private AKS, PostgreSQL, ACR, backup, landing in the prod tier (10.3) and routing
# egress through the hub firewall published by the base landing zone.

location = "centralus"
project  = "alz"

# Workstation public IP(s)/32, permitted to the workload Key Vault + ACR firewall so
# the CMK keys and secret can be created on first apply.
#   curl -4 -s https://ifconfig.me
deployer_ip_cidrs = ["203.0.113.4/32"] # <-- replace with your IPv4/32

# Cost knobs (defaults are demo-minimum).
# aks_node_vm_size = "Standard_D2s_v3"
# aks_node_count   = 2
# pg_sku           = "GP_Standard_D2s_v3"
