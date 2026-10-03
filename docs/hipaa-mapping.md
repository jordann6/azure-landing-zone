# HIPAA Security Rule: technical safeguard mapping

How this landing zone implements the HIPAA Security Rule's technical safeguards
(45 CFR 164.312), plus the administrative safeguards infrastructure can support,
with the exact Terraform behind each one. Rows are honest: where a safeguard is
organizational, inherited from Microsoft, or not built here, it says so.

**What this is not.** HIPAA compliance is organizational. It requires a Business
Associate Agreement with Microsoft (covered by the Microsoft Product Terms for
in-scope services), a risk analysis, policies, and workforce training. None of
that is infrastructure. This repo shows the technical safeguards enforced as
policy and code.

## Two layers

- **Scoring.** The built-in **HITRUST/HIPAA** initiative is assigned at the root
  management group in `terraform/hipaa.tf`, so Defender for Cloud's Regulatory
  Compliance blade scores every tier against it next to CIS. It runs with
  `enforce = false` (DoNotEnforce): it reports, it does not block or remediate.
- **Enforcement.** Custom Deny policies keyed on the `data_classification` tag.
  `data_classification` must be one of `public`, `internal`, `confidential`, or
  `phi`, and a resource group tagged `phi` cannot hold a Key Vault, storage
  account, SQL server, or PostgreSQL server with public network access. The
  guardrail test (`scripts/test-guardrails.sh`) proves both deny.

## Technical safeguards (164.312)

| Safeguard | Requirement | How it is implemented here | Resource |
|---|---|---|---|
| 164.312(a)(1) Access control | Only authorized people and software can access ePHI | Entra persona groups bound at management group scope, least privilege by tier, no standing write to Prod (PIM designed, off without Entra ID P2); managed and workload identities instead of secrets; AKS local accounts disabled | `terraform/identity.tf`, `workload/aks.tf`, `workload/workload-identity.tf` |
| 164.312(a)(2)(i) Unique user identification | Every user and workload has its own identity | Entra users and groups; one user-assigned identity per workload component (AKS, PostgreSQL, ACR, External Secrets) | `terraform/identity.tf`, `workload/*.tf` |
| 164.312(a)(2)(ii) Emergency access | A procedure to get in during an emergency | Sealed break-glass Owner group at the root management group | `terraform/identity.tf` (`lz-break-glass`) |
| 164.312(a)(2)(iv) Encryption at rest | Encrypt ePHI where reasonable | Customer-managed keys rotating every 90 days on AKS etcd, node disks, PostgreSQL storage, and ACR; Key Vault with purge protection | `terraform/keyvault.tf`, `workload/kms.tf` |
| 164.312(b) Audit controls | Record and examine activity in systems with ePHI | Central Log Analytics workspace in its own resource group; subscription Activity Log, Key Vault AuditEvent, Azure Firewall rule logs, Bastion session audit, AKS control-plane audit, PostgreSQL logs | `terraform/monitoring.tf`, `workload/aks.tf`, `workload/postgres.tf` |
| 164.312(c)(1) Integrity | Protect ePHI from improper alteration or destruction | Key Vault purge protection and soft delete; geo-redundant backup vault with soft delete; zone-redundant HA PostgreSQL | `terraform/keyvault.tf`, `workload/backup.tf`, `workload/postgres.tf` |
| 164.312(d) Person or entity authentication | Verify the identity of whoever accesses ePHI | Entra ID authentication for people, AKS (Entra RBAC), and PostgreSQL (Entra auth enabled). MFA and Conditional Access are tenant settings, not in this repo | `workload/aks.tf`, `workload/postgres.tf` |
| 164.312(e)(1) Transmission security | Guard ePHI in transit over networks | Private endpoints for Key Vault and ACR, VNet-injected PostgreSQL with no public endpoint, all egress inspected by Azure Firewall, phi resource groups denied public network access | `terraform/private_endpoints.tf`, `workload/private-endpoints.tf`, `terraform/firewall_azure.tf`, `terraform/hipaa.tf` |

## Administrative safeguards infrastructure supports (164.308)

| Safeguard | How infrastructure supports it | Resource |
|---|---|---|
| 164.308(a)(1)(ii)(D) Information system activity review | Alerts on Deny policy events, Key Vault 403s, and firewall deny spikes, routed to an action group; saved investigation queries in `docs/kql/` | `terraform/alerts.tf`, `docs/kql/` |
| 164.308(a)(3) / (a)(4) Workforce security, access management | Access granted by group membership at scope; onboarding and offboarding are group changes | `terraform/identity.tf`, `docs/access-model.md` |
| 164.308(a)(5)(ii)(D) Password management | Not in this repo: the companion [azure-secrets-lifecycle](https://github.com/jordann6/azure-secrets-lifecycle) maps stale-secret findings to this control | separate repo |
| 164.308(a)(7) Contingency plan | Zone-redundant HA PostgreSQL (zone 1 primary, zone 2 standby), geo-redundant backup | `workload/postgres.tf`, `workload/backup.tf` |

## Inherited from Microsoft

Physical safeguards (164.310: facility access, workstation and device controls in
the datacenter) are Microsoft's under the shared responsibility model.

## Honest gaps

- **PIM** is designed but not created in this deployment (no Entra ID P2).
- **MFA and Conditional Access** are tenant-level and not managed here.
- **VNet flow logs** are deferred until the azurerm v4 upgrade.
- **Log retention** is 30 days. HIPAA requires keeping compliance documentation for
  six years; log retention is a policy decision, and a real phi workload would set
  a longer retention or archive tier deliberately.
- **Cross-region failover** for the data tier is not built here.
- **The HITRUST/HIPAA initiative does not enforce.** The enforced controls are the
  custom phi policies; the initiative is a score.
