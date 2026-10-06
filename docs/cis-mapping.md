# CIS Microsoft Azure Foundations Benchmark: control mapping

How this landing zone implements the CIS Azure Foundations Benchmark, control area
by control area, with the exact Terraform that enforces each one. Rows are honest:
where a control is scored by the built-in initiative but not additionally hardened
in code, or is not applicable in a single-subscription demo, it says so.

The built-in **CIS Microsoft Azure Foundations Benchmark** initiative is assigned
at the root management group (`azurerm_management_group_policy_assignment.cis` in
`terraform/policies.tf`), so every control it defines is scored across all tiers
in Microsoft Defender for Cloud's Regulatory Compliance blade. The rows below
call out where this repo adds a preventive (Deny) control on top of that scoring.

| CIS area | Control (abbrev) | How it is implemented here | Resource |
|---|---|---|---|
| 1. Identity | Restrict privileged access, no standing prod write | Entra persona groups bound at MG scope; prod write is designed as PIM-eligible only (target model; this deployment ran with `enable_pim = false` on a tenant without Entra ID P2, see `access-model.md`) | `identity.tf` (`azuread_group.personas`, `azurerm_role_assignment.personas`, `azurerm_pim_eligible_role_assignment.prod_write`) |
| 1. Identity | Custom roles / least privilege by scope | RBAC granted at the narrowest MG (junior at Dev, platform at Workloads, finops/security at root read-only) | `identity.tf` `local.role_bindings` |
| 2. Defender | Enable Defender for Cloud + CIS assessment | Free foundational CSPM renders the CIS assessment; paid plans gated on | `monitoring.tf` (`azurerm_security_center_subscription_pricing`), initiative in `policies.tf` |
| 3. Storage | Secure transfer, no public blob, private access | Deny public IP + private-endpoint pattern; blob privatelink DNS zone provisioned | `policies.tf` `deny_public_ip`, `private_endpoints.tf` |
| 4. Database | Private data tier, no public path | Zone-redundant PostgreSQL Flexible Server, VNet-injected with public access disabled, CMK-encrypted, Entra auth on; data NSG allows 5432 only from the app/AKS subnets (plus intra-subnet HA replication); geo-redundant Backup vault with soft delete | `workload/postgres.tf`, `workload/segmentation.tf`, `workload/backup.tf` |
| 5. Logging | Central log profile, retention, Key Vault logging | Central Log Analytics workspace; subscription Activity Log export; diagnostic settings on Key Vault (AuditEvent), Azure Firewall (AZFW rule logs), Bastion (session audit), and hub VNet; alerts on Deny policy events, Key Vault 403s, and firewall deny spikes | `monitoring.tf`, `alerts.tf` |
| 6. Networking | Restrict inbound, no open admin ports | Management NSG denies inbound Internet; Bastion is the only admin path; no public VM IPs | `network.tf` NSG, `bastion.tf` |
| 6. Networking | Central egress inspection | Azure Firewall with a UDR forcing 0.0.0.0/0 through it from every spoke | `firewall_azure.tf` |
| 7. Virtual machines | No public IP, disk encryption | No VMs in the base; the opt-in FortiGate is the only VM and is off by default | `firewall.tf` (gated) |
| 8. Key Vault | Purge protection, soft delete, firewall, rotation | Key Vault with purge protection + soft delete + default-Deny network ACL + CMK rotation policy | `keyvault.tf` |
| 9. App Service | N/A | The subscription has 0 App Service quota; App Service is intentionally not used | designed-only |
| 10. Governance / tags | Enforce resource tags, allowed locations | Deny policies for owner/cost_center/environment/data_classification tags and allowed locations; Prod locked to a single region | `policies.tf` |
| 10. Cost | Budgets and alerts | Monthly subscription budget with actual + forecast alerts | `budgets.tf` |

## Preventive controls added on top of CIS scoring (Deny, not Audit)

These are enforced by custom policy at the hierarchy, so a violating request is
blocked at create time rather than only flagged after the fact:

- Deny public IP creation (`deny_public_ip`), excluding the hub resource group where
  the firewall and bastion legitimately hold public IPs (workload spokes stay denied)
- Allowed locations, tighter at Prod (`allowed_locations`, `prod_single_region`)
- Require `owner`, `cost_center`, `environment`, `data_classification` tags on resource groups (`require_owner_tag`, `require_tag`)

## Honest gaps in this demo

- **Data tier (CIS 4)**: the managed database, segmentation, and geo-redundant
  backup are built in `workload/`. Still open: backup vault immutability (needs
  azurerm v4) and cross-region database failover.
- **PIM (CIS 1)**: the JIT-to-Prod eligible assignment is in code but was not
  created in this deployment (no Entra ID P2). The persona groups and MG-scoped
  RBAC are live.
- **VNet flow logs**: built behind `enable_flow_logs` (`terraform/flow-logs.tf`); off by default.
- **HSM-backed keys (CIS 8)**: the CMK is software-protected; an HSM key needs a
  Premium vault, out of the demo budget. Documented as the upgrade path.
- **Defender paid plans**: off by default (they bill per resource). Free
  foundational CSPM covers the CIS assessment; paid plans are one flag away
  (`enable_defender_standard`). See `adr-detection.md`.
- **Single subscription**: the tiers are management groups + resource groups, not
  a subscription per tier. See `access-model.md`.

## Compute baseline additions

These controls are configured; live image and VM proofs are recorded separately
in the compute handoff after execution.

| Compute control | Implementation | Evidence |
|---|---|---|
| Approved standalone VM images | Root-MG Deny accepts only the landing-zone gallery; VMSS excluded | `terraform/compute.tf`, attributable stock-image denial |
| VM size restriction | Built-in allowed SKU Deny | `terraform/compute.tf`, attributable SKU denial |
| Host encryption | Built-in Deny for VMs/VMSS, AKS pool encryption enabled | `terraform/compute.tf`, `workload/aks.tf`, attributable encryption denial |
| Guest configuration | Prerequisite initiative with remediation identity; Linux baseline AuditIfNotExists | Assignment checks, followed by live guest validation |
| Missing update assessment | Modify for both OS types; matching Audit policy | Assignment checks; VM update settings in the compute root |
| AKS node servicing | SecurityPatch OS channel, patch Kubernetes channel, weekly off-hours window | Static provider validation only; AKS is not deployed for this session |
