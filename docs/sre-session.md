# SRE demo live session

One hourly session proves Phase 2 (GitOps, metrics, SLO alert, runbook) and
Phase 3 (stateful restore). Operational docs come first: [SLO](slo.md),
[runbooks](runbooks/). The operator runs every apply, import, push and destroy.

## Cost (Azure Retail Prices API, 2026-10-29)

Hourly, while standing. Firewall and Bastion are in the hub (centralus), the rest
in eastus2.

| Item | Rate | Session use |
|---|---|---|
| Azure Firewall Standard | $1.25/hr deployment + $0.07/hr per capacity unit | whole session |
| Bastion Standard | $0.29/hr (Basic $0.19/hr) | only for the Grafana UI |
| AKS nodes, 3 x D2s v3 | $0.096/hr each | whole session |
| Management VM, B2s | $0.0499/hr | only for the Grafana UI |
| Private endpoints (ACR, Key Vault, AKS KMS, backup blob) | $0.01/hr each | whole session |
| Standard internal load balancer (Grafana) | $0.025/hr | whole session |
| ACR Premium | $1.6666/day | billed as one day |

By usage:

| Item | Rate | Expected |
|---|---|---|
| Managed Prometheus ingestion | $0.16 per 10M samples | well under $0.10 |
| Prometheus queries | $0.001 per 10M samples | negligible |
| Log Analytics ingestion (Container Insights, firewall logs) | $2.76/GB | about 0.2 to 0.5 GB, $0.55 to $1.40 |
| AKS Backup protected instance | $12/month | about $0.40 for the day |
| Disk snapshots | $0.12/GB-month (incremental, used bytes) | negligible |
| Premium SSD P1, 4 GiB | $0.60/month | negligible |

**Estimate:** firewall $1.32 to $1.39/hr (1 or 2 capacity units) + Bastion Basic
$0.19 + nodes $0.288 + four private endpoints $0.04 + load balancer $0.025 = about
**$1.87 to $1.94/hr** standing. The Grafana UI path adds $0.15/hr (Bastion
Standard delta $0.10, VM $0.05). A 2-hour window is $3.75 to $3.90 hourly, plus
ACR's day ($1.67), the backup instance's day (about $0.40) and Log Analytics
(about $1): **about $7 to $8**, inside the $12 cap with room for one retry.
Three nodes, not two: two D2s v3 were CPU-starved by the add-ons on 2026-10-29
(see `aks_node_count` in workload/variables.tf).
The cap is an operator stop condition, not an enforced cutoff; the $20 budget
alert only notifies.

**Time is the binding constraint, not dollars.** Firewall and AKS creates take
10 to 15 minutes each, and the firewall destroy can take 10 to 30.

## Stop conditions

- 2 hours after the first hourly apply, or $12 projected, whichever is first:
  stop drilling and run teardown, whatever is unfinished.
- Any `apply` that fails twice on the same resource: tear down, fix offline.
- Teardown always runs, and `scripts/verify-teardown.sh` always runs after it.

## Staged plan

Each plan is built fresh right before its apply, after the previous layer's
outputs exist. Never reuse a stale plan.

0. **Offline, before the session.** Push `feat/aks-sre-demo`; the `SRE demo
   images` workflow builds both images. Pin them:
   `scripts/sre-pin-images.sh <slo-demo digest> <slo-grafana digest> <sha>`, commit,
   push. Set `gitops_branch = "feat/aks-sre-demo"` in `workload/terraform.tfvars`.
1. **Base, free layer.** `terraform -chdir=terraform plan -out=tfplan`, then apply.
2. **Base, network flags on** (`enable_firewall`, `enable_bastion`,
   `enable_private_endpoints`; `bastion_sku = "Standard"` only for the UI path).
   Fresh plan, apply. Hourly billing starts here: note the time.
3. **Workload** with `enable_postgres = false`, `enable_sre_demo = true`,
   `enable_aks_backup = true`. Fresh plan, apply.
4. **Images into ACR.** The three `az acr import` commands the pin script printed.
   Then wait for Flux: `az k8s-configuration flux show ... --query complianceState`.
5. **Optional UI path.** `KEEP_SSH_KEY=~/.ssh/alz-mgmt-session make deploy-compute`,
   then [grafana-access](runbooks/grafana-access.md).
6. **Drills,** in order: `scripts/drill-gitops.sh`, `scripts/drill-slo.sh`,
   `CONFIRM=<cluster>/slo-data scripts/drill-restore.sh`. Receipts land in
   `~/sre-demo-receipts/<date>/`, outside the repo.
7. **Teardown:** `make destroy` (compute, secrets, observability, workload, base,
   then verify-teardown even after a failure). Delete `~/.ssh/alz-mgmt-session`.
   On 2026-10-29 the workload destroy removed the hub peerings and the Key Vault
   private endpoint before the cluster, and the Flux configuration and backup
   instance deletes hung for 30 minutes. The cluster now depends on its whole
   network path (`make check-destroy-order` proves the graph). Fixed in code; the
   next session's teardown is the live proof. If a delete still hangs, check node
   readiness and the peerings first.
8. **After:** narrow the AKS Backup egress list from the session's
   `AZFWApplicationRule` logs, fix anything else the run found, then merge.

## Retained after teardown

`verify-teardown.sh` fails on any SRE demo survivor: the Azure Monitor workspace,
DCE, DCR, Prometheus rule groups, the demo backup vault, backup storage, the
snapshot resource group, demo identities, disks, snapshots and private endpoints.
The demo vault has soft delete Off, so nothing is held for 14 days. The existing
Postgres vault (`bv-<project>-prod`, empty) stays as it is: it is outside
`enable_postgres`, so a session with Postgres off never plans its destroy. `ci-proof/` stays
standing at $0 by design.
