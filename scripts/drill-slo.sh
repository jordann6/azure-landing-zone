#!/usr/bin/env bash
# shellcheck disable=SC2016 # wait_until conditions are single-quoted on purpose
# SLO drill (Phase 2 acceptance). Injected failure trips the fast-burn page; the
# runbook's diagnosis runs; recovery resolves the alert. Every timing is a receipt.
#
#   preflight  scrape targets up, nonzero request rate, add-ons reporting
#              (Container Insights heartbeat, Azure Policy state), Grafana
#              datasource healthy and the SLO dashboard provisioned
#   inject     create ConfigMap slo-demo-fault (FAIL_PERCENT, default 25)
#   fire       wait for SloFastBurn to fire in Azure Monitor (alert ID, time)
#   diagnose   the first checks from docs/runbooks/slo-fast-burn.md
#   recover    delete the ConfigMap, wait for SloFastBurn to resolve
#   receipt    you enter when the page email arrived
#
# Time to fire depends on how long healthy traffic ran first, because the 1h
# window has to cross 7.2% errors: with T minutes of healthy traffic and a 25%
# failure rate, the 1h ratio crosses after about 0.4 x T minutes (docs/slo.md).
#
# The fault ConfigMap is removed on exit, even after a failure.
#
# Requires: az login, workload/ applied with enable_sre_demo=true, images pinned
# and imported, Flux Compliant.
set -uo pipefail
# shellcheck source=scripts/sre-lib.sh
source "$(dirname "$0")/sre-lib.sh"
load_outputs || exit 1
FAIL_PERCENT="${FAIL_PERCENT:-25}"
FIRE_TIMEOUT="${FIRE_TIMEOUT:-1500}"
RESOLVE_TIMEOUT="${RESOLVE_TIMEOUT:-1200}"
R=slo-drill.json
pass=0
fail=0
ok()  { echo "  PASS: $1"; pass=$((pass + 1)); }
bad() { echo "  FAIL: $1"; fail=$((fail + 1)); }
gt0() { awk -v v="$1" 'BEGIN { exit !(v != "none" && v + 0 > 0) }'; }

remove_fault() { kx "kubectl delete configmap slo-demo-fault -n slo-demo --ignore-not-found" >/dev/null 2>&1 || true; }
trap remove_fault EXIT

echo "== SLO drill =="

echo "-- preflight --"
up="$(promq 'count(up{namespace="slo-demo"} == 1)')"
if [ "$up" != "none" ] && [ "${up%.*}" -ge 3 ]; then ok "${up} slo-demo targets up"; else bad "slo-demo targets up: ${up}"; fi
rate="$(promq 'slo:requests:rate5m')"
if gt0 "$rate"; then ok "request rate ${rate} rps"; else bad "request rate is ${rate}"; fi
receipt "$R" baseline_rps "$rate"

law_guid="$(terraform -chdir="$ROOT/terraform" output -raw log_analytics_workspace_guid 2>/dev/null)"
if [ -n "$law_guid" ]; then
  hb="$(az monitor log-analytics query -w "$law_guid" \
    --analytics-query "KubePodInventory | where TimeGenerated > ago(15m) | where ClusterName == '${AKS}' | count" \
    --query '[0].Count' -o tsv 2>/dev/null)"
  receipt "$R" container_insights_rows_15m "${hb:-0}"
  if [ "${hb:-0}" -gt 0 ]; then ok "Container Insights reporting (${hb} KubePodInventory rows in 15m)"; else bad "no Container Insights data from ${AKS} in 15m"; fi
fi
aks_id="$(az aks show -g "$RG" -n "$AKS" --query id -o tsv)"
pol="$(az policy state list --resource "$aks_id" --query 'length(@)' -o tsv 2>/dev/null)"
receipt "$R" policy_states_on_cluster "${pol:-0}"
echo "  INFO: ${pol:-0} Azure Policy compliance records on the cluster"

# The $ signs expand inside the Grafana pod, not here.
# shellcheck disable=SC2016
graf="$(kx 'kubectl exec -n observability deploy/grafana -- sh -c "p=\$(cat /mnt/secrets/grafana-admin-password); curl -s -u admin:\$p localhost:3000/api/datasources/uid/amw/health; echo; curl -s -o /dev/null -w %{http_code} -u admin:\$p localhost:3000/api/dashboards/uid/slo-demo"')"
if grep -q '"status":"OK"' <<<"$graf"; then ok "Grafana datasource health OK (workload identity to the workspace)"; else bad "Grafana datasource health: $(head -c 200 <<<"$graf")"; fi
if [ "$(tail -1 <<<"$graf")" = "200" ]; then ok "SLO dashboard provisioned from Git"; else bad "SLO dashboard not found"; fi
for q in 'slo:errors:ratio_rate5m' 'histogram_quantile(0.95, sum by (le) (rate(slo_demo_request_duration_seconds_bucket{namespace="slo-demo"}[5m])))' 'slo:errors:ratio_rate1h / 0.005'; do
  v="$(promq "$q")"
  if [ "$v" != "none" ]; then ok "dashboard query returns data: ${q:0:48} = ${v}"; else bad "no data for ${q}"; fi
done

existing="$(alerts_for SloFastBurn | awk '$2 == "Fired"' | head -1)"
if [ -n "$existing" ]; then bad "SloFastBurn already firing before injection: $existing"; exit 1; fi

echo "-- inject ${FAIL_PERCENT}% failures --"
kx "kubectl create configmap slo-demo-fault -n slo-demo --from-literal=fail_percent=${FAIL_PERCENT}" >/dev/null || { bad "could not create the fault ConfigMap"; exit 1; }
t_inject="$(epoch)"
receipt "$R" fault_injected_at "$(now)"
receipt "$R" fault_percent "$FAIL_PERCENT"

echo "-- wait for SloFastBurn to fire (up to ${FIRE_TIMEOUT}s) --"
fired_line() { alerts_for SloFastBurn | awk '$2 == "Fired"' | head -1; }
if wait_until "$FIRE_TIMEOUT" 30 'test -n "$(fired_line)"'; then
  read -r alert_id _ alert_start _ <<<"$(fired_line)"
  receipt "$R" fast_burn_alert_id "$alert_id"
  receipt "$R" fast_burn_fired_at "$alert_start"
  receipt "$R" seconds_to_fire "$(($(epoch) - t_inject))"
  ok "SloFastBurn fired ${alert_start} (${alert_id})"
else
  bad "SloFastBurn did not fire within ${FIRE_TIMEOUT}s (1h ratio now $(promq 'slo:errors:ratio_rate1h'))"
fi

echo "-- diagnose (docs/runbooks/slo-fast-burn.md, first checks) --"
echo "  1. error ratio by window"
for w in 5m 1h; do echo "     ${w}: $(promq "slo:errors:ratio_rate${w}")"; done
echo "  2. pods, restarts, recent events"
kx "kubectl get pods -n slo-demo -o wide; kubectl get events -n slo-demo --sort-by=.lastTimestamp | tail -5" | sed 's/^/     /'
echo "  3. what changed: rollout history and config objects outside Git"
kx "kubectl rollout history deploy/slo-demo -n slo-demo | tail -3; kubectl get configmap -n slo-demo -L kustomize.toolkit.fluxcd.io/name" | sed 's/^/     /'
receipt "$R" diagnosis_finding "configmap slo-demo-fault present and not owned by Flux"

echo "-- recover: remove the fault --"
remove_fault
t_recover="$(epoch)"
receipt "$R" fault_removed_at "$(now)"
resolved_line() { alerts_for SloFastBurn | awk -v id="${alert_id:-none}" '$1 == id && $2 == "Resolved"' | head -1; }
if [ -n "${alert_id:-}" ] && wait_until "$RESOLVE_TIMEOUT" 30 'test -n "$(resolved_line)"'; then
  read -r _ _ _ resolved_at <<<"$(resolved_line)"
  receipt "$R" fast_burn_resolved_at "$resolved_at"
  receipt "$R" seconds_to_resolve "$(($(epoch) - t_recover))"
  ok "SloFastBurn resolved ${resolved_at}"
else
  bad "SloFastBurn not resolved within ${RESOLVE_TIMEOUT}s"
fi

echo "-- page receipt --"
read -r -p "  time the Sev 1 email arrived (UTC, e.g. 14:07:31), blank if none: " email_at
receipt "$R" page_email_received_at "${email_at:-not received}"
if [ -n "$email_at" ]; then ok "page email received ${email_at}"; else bad "no page email recorded"; fi

echo ""
echo "Receipts: $RECEIPTS_DIR/$R"
echo "${pass} passed, ${fail} failed"
[ "$fail" -eq 0 ]
