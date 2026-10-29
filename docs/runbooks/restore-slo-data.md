# Runbook: restore the slo-data namespace from AKS Backup

**When.** The `slo-data` namespace, its Postgres volume, or the data in it is lost
or corrupted. `scripts/drill-restore.sh` runs these same steps as a drill.

**What this recovers.** Same region, same cluster (or another cluster in the same
region with the backup extension), from the operational tier: a crash-consistent
snapshot of the Postgres disk plus the namespace's Kubernetes objects. Postgres
replays its WAL on start. Not regional DR, not an application-consistent backup.

**What it loses.** Every write after the data in the recovery point was captured.
That is earlier than the point's `recoveryPointTime`: on 2026-10-29 the point
was stamped 17:40:54 but held data captured at 17:38:27, about 2.5 minutes
before. Measure loss from the highest recovered write, never from the timestamp.
The scheduled cadence is 4 hours; take an on-demand backup before any planned
risky change.

## Steps

1. **Stop the bleeding.** Suspend Flux, so it does not recreate an empty namespace
   on top of the restore:
   `az k8s-configuration flux update -g "$RG" -c "$AKS" -t managedClusters -n sre-demo --kind git --url "$GITOPS_URL" --branch "$GITOPS_BRANCH" --suspend true`.
   The CLI rejects `--suspend` alone ("Invalid source kind match"); it must
   resend the Git source, read from
   `az k8s-configuration flux show ... --query gitRepository`.
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
6. **Resume Flux** (the same command with `--suspend false`) and wait for `Compliant`. The restored
   objects match Git, so Flux changes nothing; a diff here means the backup and
   Git disagreed.
7. **Record** the recovery point time, the failure time, the last durable write
   before the failure, the highest recovered write, and how long the service was
   down. The drill on 2026-10-29: last durable write 3301, recovered 3007 with
   no gaps, 294 writes lost, restore job 219s, writes resumed 405s after the
   namespace was deleted.

## Escalate

Restore job `Failed`, or the restored Postgres does not start: keep Flux
suspended, keep the failed namespace for evidence, and check the job's error
(`az dataprotection job show --ids <job>`) and the extension pods
(`kubectl get pods -n dataprotection-microsoft`).

A backup instance stuck in `ProtectionError` with
`UserErrorExtensionMSIMissingPermissionsOnBackupStorageLocation` means the
extension identity cannot list the storage account keys. It needs Storage Account
Contributor on the account as well as Storage Blob Data Contributor (the Learn
prerequisites table lists only the second); `workload/sre-backup.tf` grants both.
