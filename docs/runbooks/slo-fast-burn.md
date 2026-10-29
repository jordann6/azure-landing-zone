# Runbook: SloFastBurn (Sev 1, page)

**Symptom.** slo-demo's 5xx ratio is over 7.2% on both the 1h and 5m windows: at
this rate the 30-day error budget is gone in about two days.

All kubectl commands go through the control plane, because the cluster is
private with local accounts off:

```bash
RG=$(terraform -chdir=workload output -raw resource_group_name)
AKS=$(terraform -chdir=workload output -raw aks_cluster_name)
k() { az aks command invoke -g "$RG" -n "$AKS" --command "$*" --query logs -o tsv; }
```

## First three checks

1. **Is it real, and how bad?** Error ratio by window on the dashboard (Burn rate
   panel), or PromQL `slo:errors:ratio_rate5m` and `slo:errors:ratio_rate1h`. A
   5m ratio already falling means recovery is under way; watch, do not change
   things.
2. **Are the pods healthy?**
   `k "kubectl get pods -n slo-demo -o wide; kubectl get events -n slo-demo --sort-by=.lastTimestamp | tail -20"`.
   Crash loops, OOMKilled, failing readiness, or every pod on one node.
3. **What changed?** Flux revision and recent rollouts:
   `az k8s-configuration flux show -g "$RG" -c "$AKS" -t managedClusters -n sre-demo --query "{state:complianceState, rev:sourceSyncedCommitId}"`
   and `k "kubectl rollout history deploy/slo-demo -n slo-demo"`. Then config that
   Git does not own: `k "kubectl get configmap -n slo-demo -L kustomize.toolkit.fluxcd.io/name"`.
   An object with no Flux label was put there by hand.

## Likely causes

| Cause | Tell |
|---|---|
| Fault switch left on | ConfigMap `slo-demo-fault` exists (no Flux label); `slo_demo_fault_percent` > 0 |
| Bad release | New revision in rollout history, errors start at the rollout time |
| Capacity | Throttling or OOMKilled, p95 latency up with errors |
| Dependency or node | Errors on pods of one node only; node NotReady |

## Fix

- **Fault switch:** `k "kubectl delete configmap slo-demo-fault -n slo-demo"`.
  The pods re-read the file within the kubelet's ConfigMap sync (about a minute).
- **Bad release:** revert the commit in Git and push; Flux rolls back within its
  60s interval. Do not `kubectl rollout undo`: Flux would put the bad revision back.
- **Capacity:** raise replicas or limits in Git, push.

## Confirm recovery

The 5m ratio drops below 7.2% within minutes; `SloFastBurn` resolves (auto-resolve
after 5 minutes clear). The 1h window stays elevated for up to an hour, which is
expected, and is why the pair needs both windows to fire.

## Escalate

Not recovering 15 minutes after a fix, or the cause is not in the table: page the
platform owner, and keep this alert open as the incident record.
