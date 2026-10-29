# Runbook: restore the slo-data namespace from AKS Backup

**When.** The `slo-data` namespace, its Postgres volume, or the data in it is lost
or corrupted. `scripts/drill-restore.sh` runs these same steps as a drill.

**What this recovers.** Same region, same cluster (or another cluster in the same
region with the backup extension), from the operational tier: a crash-consistent
snapshot of the Postgres disk plus the namespace's Kubernetes objects. Postgres
replays its WAL on start. Not regional DR, not an application-consistent backup.

**What it loses.** Every write after the recovery point. The scheduled cadence
is 4 hours; take an on-demand backup before any planned risky change.

## Steps

1. **Stop the bleeding.** Suspend Flux, so it does not recreate an empty namespace
   on top of the restore:
   `az k8s-configuration flux update -g "$RG" -c "$AKS" -t managedClusters -n sre-demo --suspend true`
2. **Pick the recovery point.** Latest before the incident:
   `az dataprotection recovery-point list -g "$RG" --vault-name "$VAULT" --backup-instance-name "$BI" --query "sort_by([], &properties.recoveryPointTime)[-1]"`
3. **Clear what is left.** A partial namespace makes the restore skip objects
   (conflict policy Skip): `kubectl delete namespace slo-data`.
4. **Restore.** Build the request with `initialize-restoreconfig` (included
   namespace `slo-data`, `RestoreWithVolumeData`), then `initialize-for-data-recovery`,
   `validate-for-restore` and `restore trigger`. The exact commands are in
   `scripts/drill-restore.sh`, step 6.
5. **Verify the data.** `postgres-0` Ready; then highest sequence and no gaps:
   `SELECT max(seq), count(*) = max(seq) FROM writes`.
6. **Resume Flux** (`--suspend false`) and wait for `Compliant`. The restored
   objects match Git, so Flux changes nothing; a diff here means the backup and
   Git disagreed.
7. **Record** the recovery point time, the failure time, the last durable write
   before the failure, the highest recovered write, and how long the service was
   down.

## Escalate

Restore job `Failed`, or the restored Postgres does not start: keep Flux
suspended, keep the failed namespace for evidence, and check the job's error
(`az dataprotection job show --ids <job>`) and the extension pods
(`kubectl get pods -n dataprotection-microsoft`).
