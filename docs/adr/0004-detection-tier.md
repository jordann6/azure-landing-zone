# ADR-0004: Threat detection on the free Defender tier, no Sentinel

- **Status:** accepted
- **Date:** 2026-10-06

## Context

The AWS zone runs GuardDuty, Config and an optional Security Hub integration. The GCP
zone streams Security Command Center findings to Pub/Sub once SCC is activated. The
Azure zone detects through Defender for Cloud's free foundational CSPM, the activity
log alerts in `terraform/alerts.tf` and `observability/`, and the firewall, Key Vault
and Bastion logs in the central workspace. It has no threat-detection service and no
SIEM. The posture is deploy, demo, destroy, under about $7 a session.

## Decision

1. **No Microsoft Sentinel.** Sentinel bills per GB ingested into the workspace, on
   top of Log Analytics ingestion, and a SIEM has no value in a stack that lives for
   hours. Microsoft's 31-day trial (first 10 GB a day free, 20 workspaces per tenant)
   is real, but it ends inside the lifetime of a portfolio piece that stays up for
   years, so building toward it would set a billing trap.
2. **Paid Defender plans stay behind `enable_defender_standard`, off by default.**
   The flag already exists in the base root and turns on Servers, Key Vaults,
   Storage Accounts and Resource Manager (`terraform/monitoring.tf`).
3. **Findings routing is wired anyway** (`observability/findings.tf`), so turning a
   plan on needs no further Terraform: High alerts and assessments already flow to
   the workspace and the High alert is armed.

## What each cloud actually gives you

| | AWS | GCP | Azure here |
|---|---|---|---|
| Threat detection | GuardDuty delegated across accounts | SCC (Premium or Enterprise for scored findings) | Paid Defender plans, off |
| Posture and compliance | Config, optional Security Hub CIS | SCC findings, CIS alert metrics | Free CSPM, CIS and HIPAA initiatives scored |
| Findings routing | EventBridge to SNS, HIGH and CRITICAL | Pub/Sub, behind `enable_scc_notifications` | Continuous export to the workspace, alert on High |
| SIEM | none | none | none |

Azure's gap is real: nothing here looks at behaviour. A compromised identity that
stays inside its own permissions would not be flagged. What the zone does give is
preventive denial, change alerts on every guardrail and boundary, and a complete
audit trail to investigate from.

## Cost reference

Prices from Microsoft's Defender for Cloud and Sentinel pricing pages, checked
2026-10-06. They change, and the Key Vault plan's price was not on the pages I
read, so confirm before enabling.

| Plan | Unit price | Note |
|---|---|---|
| Defender for Servers Plan 1 | $0.007 per server per hour, about $5 a month | Per VM, including the management VM |
| Defender for Servers Plan 2 | $0.02 per server per hour, about $15 a month | |
| Defender for Storage | $0.0134 per storage account per hour | Counts every account, including the state backend and flow-log storage |
| Defender for Resource Manager | $4 per million API calls | Usage-priced, so Terraform applies and destroys add to it |
| Defender for Key Vault | not verified | |
| Sentinel | per GB ingested, commitment tiers start at 100 GB a day | |

Defender for Cloud is free for the first 30 days after a plan is enabled.

## Consequences

- Enabling all four plans for a one-day demo costs a few dollars, mostly Storage by
  the hour across accounts. It is affordable for a single session, which is why the
  flag exists, but it would run up a bill if left on.
- The Servers plan is pinned by `defender_servers_subplan` (default P1, the cheaper
  tier). Set P2 deliberately if you want the extra Servers features. Azure applies the
  subplan only to the `VirtualMachines` plan; the others take none.
- Defender for Containers on the AKS cluster is covered separately in
  `azure-aks-runtime-security` and is not part of this flag.

## When to revisit

Add Sentinel if the zone ever holds a real workload with real telemetry, or if a
review asks for correlation across the three clouds, which this design rules out by
keeping them isolated.
