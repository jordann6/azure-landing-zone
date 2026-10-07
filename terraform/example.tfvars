# Copy to terraform.tfvars (gitignored) and edit. The real terraform.tfvars is
# never committed; every flag defaults to its production-canonical value in code,
# so main stays complete and a local tfvars only trims cost for a demo.

# --- Region / naming ---
location = "centralus"
project  = "alz"

# Compute policies are always assigned. Include the AKS node size if changing it.
# allowed_vm_skus = ["Standard_B2s", "Standard_B2s_v2", "Standard_D2s_v3", "Standard_D2s_v5"]

# --- Deployer access so the CMK can be created on first apply ---
# The Key Vault firewall default-denies; add your workstation's public IP.
# Find it with:  curl -s https://ifconfig.me
deployer_ip_cidrs = ["203.0.113.4/32"] # <-- replace with your IP/32

# --- Cost control: cheap governance-only apply -------------------------------
# Leave these true (the default) for the full demo. Set false to stand up only
# the free layer (MGs, Deny policies, CIS, identity, logging, Key Vault) with no
# hourly-billed network resources.
# enable_firewall          = false
# enable_bastion           = false
# enable_private_endpoints = false

# --- Identity: turn off if the demo tenant lacks Graph/P2 permissions --------
# create_entra_identity = false
# enable_pim            = false

# --- Defender for Cloud paid plans (bill per resource; off by default) -------
# enable_defender_standard = true

# --- VNet flow logs + traffic analytics (hub and prod; billed by volume) ---
# enable_flow_logs        = true
# flow_log_retention_days = 7

# --- FinOps ---
budget_amount = 20
alert_email   = "you@example.com"
