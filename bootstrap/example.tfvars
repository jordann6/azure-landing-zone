# Copy to terraform.tfvars (gitignored).
location = "centralus"

# The Key Vault firewall default-denies; add your workstation's public IP so the
# key can be created. Find it with:  curl -s https://ifconfig.me
deployer_ip_cidrs = ["203.0.113.4/32"] # <-- replace with your IP/32

# Allow (default): Entra ID + RBAC is the perimeter. Deny: also IP-allowlist the
# storage account to deployer_ip_cidrs.
network_default_action = "Allow"
