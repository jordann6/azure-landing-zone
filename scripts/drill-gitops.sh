#!/usr/bin/env bash
# shellcheck disable=SC2016 # wait_until conditions are single-quoted on purpose
# GitOps proofs for the SRE demo (Phase 2 acceptance):
#   1. the Flux configuration is Compliant
#   2. drift: a manual `kubectl scale` of slo-demo is reverted by Flux (timed)
#   3. commit: a pushed change to gitops/ reaches the cluster with no kubectl
#      (timed from when you enter the pushed SHA)
#
# Step 3 waits for you: change RPS in gitops/apps/slo-demo/loadgen.yaml, commit,
# push the tracked branch, then paste the commit SHA. Skip it with SKIP_COMMIT=1.
#
# Requires: az login, workload/ applied with enable_sre_demo=true.
set -uo pipefail
# shellcheck source=scripts/sre-lib.sh
source "$(dirname "$0")/sre-lib.sh"
load_outputs || exit 1
R=gitops-drill.json
pass=0
fail=0
ok()  { echo "  PASS: $1"; pass=$((pass + 1)); }
bad() { echo "  FAIL: $1"; fail=$((fail + 1)); }

flux_show() {
  az k8s-configuration flux show -g "$RG" -c "$AKS" -t managedClusters -n "$FLUX_CONFIG" -o json 2>/dev/null
}

echo "== GitOps drill =="

echo "-- 1. Flux configuration state --"
state="$(flux_show | jq -r '.complianceState')"
rev="$(flux_show | jq -r '.sourceSyncedCommitId')"
receipt "$R" flux_compliance "$state"
receipt "$R" flux_revision "$rev"
if [ "$state" = "Compliant" ]; then ok "Flux is Compliant at $rev"; else bad "Flux is $state"; fi

echo "-- 2. drift: scale slo-demo to 1 by hand, expect Flux to restore 3 --"
replicas() { kx "kubectl get deploy slo-demo -n slo-demo -o jsonpath='{.spec.replicas}'" | tail -1; }
# The timing comes from the cluster, not from this loop. Each poll is a
# runCommand round trip of 20 to 40 seconds, so the time the loop notices the
# revert overstates it. The injection time is the cluster clock right after the
# scale, and the revert time is when kustomize-controller last wrote the
# Deployment (its managedFields entry). Flux applies only when it finds a diff,
# so that write is the revert.
injected="$(kx "kubectl scale deploy/slo-demo -n slo-demo --replicas=1 >/dev/null && date -u +%Y-%m-%dT%H:%M:%SZ" | tail -1)"
receipt "$R" drift_injected_at "$injected"
flux_write() {
  kx "kubectl get deploy slo-demo -n slo-demo -o jsonpath='{range .metadata.managedFields[?(@.manager==\"kustomize-controller\")]}{.time}{\"\\n\"}{end}'" |
    grep -E '^[0-9]{4}-' | sort | tail -1
}
if wait_until 300 10 'test "$(replicas)" = "3"'; then
  reverted="$(flux_write)"
  secs="$(jq -rn --arg a "$injected" --arg b "$reverted" '($b | fromdateiso8601) - ($a | fromdateiso8601)' 2>/dev/null)"
  if [ -n "$reverted" ] && [ -n "$secs" ] && [ "$secs" -ge 0 ]; then
    receipt "$R" drift_reverted_at "$reverted (kustomize-controller managedFields)"
    receipt "$R" drift_reverted_seconds "$secs"
    ok "Flux reverted the manual scale in ${secs}s (cluster timestamps)"
  else
    bad "replicas back to 3, but no kustomize-controller write after $injected (reverted by something else?)"
  fi
else
  bad "replicas not restored to 3 within 300s"
fi

if [ "${SKIP_COMMIT:-0}" != "1" ]; then
  echo "-- 3. commit: change gitops/, push, paste the SHA --"
  read -r -p "  pushed commit SHA: " sha
  want="$(git -C "$ROOT" show "${sha}:gitops/apps/slo-demo/loadgen.yaml" | awk '/name: RPS/{getline; gsub(/[^0-9]/,""); print}')"
  t0="$(epoch)"
  receipt "$R" commit_sha "$sha"
  live_rps() {
    kx "kubectl get deploy slo-loadgen -n slo-demo -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name==\"RPS\")].value}'" | tail -1
  }
  if [ -n "$want" ] && wait_until 600 15 'test "$(live_rps)" = "$want"'; then
    receipt "$R" commit_converged_seconds "$(($(epoch) - t0))"
    ok "commit ${sha:0:7} live (RPS=$want) after $(($(epoch) - t0))s, no kubectl apply"
  else
    bad "commit ${sha:0:7} not live within 600s (want RPS=${want:-unknown})"
  fi
fi

echo ""
echo "Receipts: $RECEIPTS_DIR/$R"
echo "${pass} passed, ${fail} failed"
[ "$fail" -eq 0 ]
