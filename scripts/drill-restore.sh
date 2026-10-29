#!/usr/bin/env bash
# shellcheck disable=SC2016 # wait_until conditions are single-quoted on purpose
# Stateful restore drill (Phase 3), AKS Backup operational tier. DESTRUCTIVE: it
# deletes the slo-data namespace and restores it from a snapshot.
#
# Refuses to run unless CONFIRM is exactly "<cluster>/slo-data", for example:
#   CONFIRM=aks-alz-prod/slo-data scripts/drill-restore.sh
#
#   1. on-demand backup; wait for the job; record the recovery point ID and time
#   2. record the last acknowledged write (max seq) before the loss
#   3. suspend the Flux configuration so nothing recreates the namespace
#   4. stop the writer; record the failure boundary (max seq, timestamp)
#   5. delete the namespace (simulated loss); record the failure time
#   6. restore the namespace from the recovery point; record the job ID
#   7. when Postgres is Ready, read the highest recovered sequence
#   8. resume Flux; confirm the writer acks again and Flux is Compliant
#
# Lost writes are measured in the database, not from pod logs (which go away
# with the namespace): rows written before the failure time that the restored
# database no longer holds. Every acknowledged insert was committed with
# synchronous_commit on, so an ack is a durable write.
#
# Scope: same-region, same-cluster namespace recovery from a crash-consistent
# storage snapshot. Not regional DR, not an application-consistent backup.
#
# Requires: az login, workload/ applied with enable_sre_demo and enable_aks_backup.
set -uo pipefail
# shellcheck source=scripts/sre-lib.sh
source "$(dirname "$0")/sre-lib.sh"
load_outputs || exit 1
NS=slo-data
VAULT="$(tf_out aks_backup_vault_name)"
BI="$(tf_out aks_backup_instance_name)"
LOCATION="$(az group show -n "$RG" --query location -o tsv)"
R=restore-drill.json

if [ "${CONFIRM:-}" != "${AKS}/${NS}" ]; then
  echo "Refusing: set CONFIRM=${AKS}/${NS} to run this destructive drill." >&2
  exit 2
fi
[ -n "$VAULT" ] && [ -n "$BI" ] || { echo "backup outputs missing; enable_aks_backup applied?" >&2; exit 1; }

flux_suspend() {
  az k8s-configuration flux update -g "$RG" -c "$AKS" -t managedClusters -n "$FLUX_CONFIG" --suspend "$1" -o none
}
# Never leave Flux suspended, whatever happens below.
trap 'flux_suspend false 2>/dev/null || true' EXIT

psql_q() {
  kx "kubectl exec -n ${NS} postgres-0 -- psql -U slo -d slo -tAc \"$1\"" | tail -1 | tr -d '[:space:]'
}
job_wait() {
  local id="$1" status
  for _ in $(seq 1 120); do
    status="$(az dataprotection job show --ids "$id" --query properties.status -o tsv 2>/dev/null)"
    case "$status" in
      Completed) return 0 ;;
      Failed | Cancelled | CompletedWithWarnings)
        echo "  job $status" >&2
        [ "$status" = "CompletedWithWarnings" ] && return 0
        return 1
        ;;
    esac
    sleep 15
  done
  return 1
}
latest_job_id() {
  az dataprotection job list -g "$RG" --vault-name "$VAULT" -o json 2>/dev/null |
    jq -r --arg op "$1" --arg since "$2" '
      [.[] | select(.properties.operationCategory == $op and .properties.startTime >= $since)]
      | sort_by(.properties.startTime) | last | .id // empty'
}

echo "== Restore drill: ${AKS}/${NS} =="
receipt "$R" backup_cadence "every 4h (PT4H), retained 1 day, operational tier"

echo "-- 1. on-demand backup --"
rule="$(az dataprotection backup-policy show -g "$RG" --vault-name "$VAULT" -n "$(basename "$(az dataprotection backup-instance show -g "$RG" --vault-name "$VAULT" -n "$BI" --query properties.policyInfo.policyId -o tsv)")" \
  --query "properties.policyRules[?objectType=='AzureBackupRule'].name | [0]" -o tsv)"
since="$(now)"
az dataprotection backup-instance adhoc-backup -g "$RG" --vault-name "$VAULT" -n "$BI" \
  --rule-name "$rule" --retention-tag-override Default -o none || { echo "adhoc backup failed" >&2; exit 1; }
job=""
wait_until 300 10 'test -n "$(latest_job_id Backup "$since")"' && job="$(latest_job_id Backup "$since")"
# Either a missing job or a failed one stops the drill.
# shellcheck disable=SC2015
[ -n "$job" ] && job_wait "$job" || { echo "backup job did not complete" >&2; exit 1; }
rp="$(az dataprotection recovery-point list -g "$RG" --vault-name "$VAULT" --backup-instance-name "$BI" -o json |
  jq -r 'sort_by(.properties.recoveryPointTime) | last | "\(.name) \(.properties.recoveryPointTime)"')"
read -r rp_id rp_time <<<"$rp"
receipt "$R" backup_job_id "$(basename "$job")"
receipt "$R" recovery_point_id "$rp_id"
receipt "$R" recovery_point_time "$rp_time"

echo "-- 2. last acknowledged write before the loss --"
receipt "$R" seq_at_recovery_point_check "$(psql_q 'SELECT max(seq) FROM writes')"

echo "-- 3. suspend Flux --"
flux_suspend true || { echo "could not suspend Flux" >&2; exit 1; }
receipt "$R" flux_suspended_at "$(now)"

echo "-- 4. stop the writer; failure boundary --"
kx "kubectl scale deploy/slo-writer -n ${NS} --replicas=0 && kubectl wait --for=delete pod -l app=slo-writer -n ${NS} --timeout=60s" >/dev/null
boundary_seq="$(psql_q 'SELECT max(seq) FROM writes')"
receipt "$R" last_durable_seq_before_failure "$boundary_seq"
receipt "$R" last_durable_write_at "$(psql_q "SELECT to_char(max(written_at) AT TIME ZONE 'UTC', 'YYYY-MM-DD_HH24:MI:SS') FROM writes")Z"

echo "-- 5. simulated loss: delete the namespace --"
t_fail="$(epoch)"
fail_at="$(now)"
kx "kubectl delete namespace ${NS} --wait=true --timeout=300s" >/dev/null
receipt "$R" failure_at "$fail_at"

echo "-- 6. restore from ${rp_id} --"
cfg="$(mktemp)"
trap 'rm -f "$cfg"; flux_suspend false 2>/dev/null || true' EXIT
az dataprotection backup-instance initialize-restoreconfig --datasource-type AzureKubernetesService -o json |
  jq --arg ns "$NS" '.included_namespaces = [$ns] | .conflict_policy = "Skip" | .persistent_volume_restore_mode = "RestoreWithVolumeData" | .include_cluster_scope_resources = true' >"$cfg"
aks_id="$(az aks show -g "$RG" -n "$AKS" --query id -o tsv)"
req="$(mktemp)"
az dataprotection backup-instance restore initialize-for-data-recovery --datasource-type AzureKubernetesService \
  --restore-location "$LOCATION" --source-datastore OperationalStore --recovery-point-id "$rp_id" \
  --target-resource-id "$aks_id" --restore-configuration "$cfg" -o json >"$req"
az dataprotection backup-instance validate-for-restore -g "$RG" --vault-name "$VAULT" -n "$BI" --restore-request-object "$req" -o none ||
  { echo "restore validation failed" >&2; exit 1; }
since="$(now)"
t_restore="$(epoch)"
az dataprotection backup-instance restore trigger -g "$RG" --vault-name "$VAULT" -n "$BI" --restore-request-object "$req" -o none ||
  { echo "restore trigger failed" >&2; exit 1; }
rjob=""
wait_until 300 10 'test -n "$(latest_job_id Restore "$since")"' && rjob="$(latest_job_id Restore "$since")"
receipt "$R" restore_job_id "$(basename "${rjob:-none}")"
receipt "$R" restore_started_at "$since"
# shellcheck disable=SC2015
[ -n "$rjob" ] && job_wait "$rjob" || echo "  WARN: restore job not Completed; checking the namespace anyway" >&2
receipt "$R" restore_job_seconds "$(($(epoch) - t_restore))"

echo "-- 7. Postgres Ready; highest recovered write --"
wait_until 600 15 'kx "kubectl get pod postgres-0 -n ${NS} -o jsonpath={.status.containerStatuses[0].ready}" 2>/dev/null | grep -q true'
t_ready="$(epoch)"
receipt "$R" postgres_ready_at "$(now)"
# The restored writer Deployment was scaled to 1 at backup time, so it may
# already be writing again. Count only rows written before the failure.
recovered="$(psql_q "SELECT max(seq) FROM writes WHERE written_at < '${fail_at}'")"
contiguous="$(psql_q "SELECT count(*) = max(seq) FROM writes WHERE written_at < '${fail_at}'")"
receipt "$R" last_recovered_seq "$recovered"
receipt "$R" recovered_rows_contiguous "$contiguous"
receipt "$R" lost_writes "$((boundary_seq - recovered))"
receipt "$R" data_loss_window "recovery point ${rp_time} to failure ${fail_at}"
receipt "$R" seconds_failure_to_postgres_ready "$((t_ready - t_fail))"

echo "-- 8. resume Flux; writer acking; Compliant --"
flux_suspend false
trap 'rm -f "$cfg" "$req"' EXIT
wait_until 600 20 'test "$(az k8s-configuration flux show -g "$RG" -c "$AKS" -t managedClusters -n "$FLUX_CONFIG" --query complianceState -o tsv)" = Compliant'
receipt "$R" flux_resumed_state "$(az k8s-configuration flux show -g "$RG" -c "$AKS" -t managedClusters -n "$FLUX_CONFIG" --query complianceState -o tsv)"
wait_until 300 15 'kx "kubectl logs deploy/slo-writer -n ${NS} --tail=3" 2>/dev/null | grep -q "\"evt\":\"ack\""'
t_service="$(epoch)"
receipt "$R" writer_acking_at "$(now)"
receipt "$R" seconds_failure_to_writes_resumed "$((t_service - t_fail))"

echo ""
echo "Lost writes: $((boundary_seq - recovered)) (last durable ${boundary_seq}, recovered ${recovered}, contiguous ${contiguous})"
echo "Receipts: $RECEIPTS_DIR/$R"
