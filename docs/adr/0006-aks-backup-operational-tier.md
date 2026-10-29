# ADR-0006: AKS Backup on the operational tier for the stateful namespace

- **Status:** accepted
- **Date:** 2026-10-29

## Context

The SRE demo runs Postgres as a StatefulSet in its own namespace (`slo-data`) on a
CMK-encrypted Premium SSD (disk encryption set). Phase 3 has to prove a restore
after the namespace is deleted, with the data loss measured, inside an hourly
session that is destroyed afterwards. Teardown must leave nothing billable behind.
The existing Postgres Flexible Server vault (`bv-<project>-prod`) is retained and
must never be destroyed by the demo.

## Decision

AKS Backup, **operational tier only**, in a separate demo vault
(`bv-<project>-aks-demo`, soft delete Off, `workload/sre-backup.tf`): incremental
disk snapshots in a dedicated resource group plus cluster resource metadata in a
private, CMK-encrypted storage container reached over a private endpoint. The
backup instance covers `slo-data` with cluster-scoped resources (so the restored
claims get their volumes back). The drill takes an on-demand backup right before
the simulated loss; the 4-hour schedule is the stated cadence, not what the drill
restores from.

## Alternatives rejected

| Option | Why not |
| ------ | ------- |
| Vault tier | Rejects disks with a disk encryption set, which every PV here has, and is not deployable through Terraform. |
| Velero self-managed | Same snapshot mechanism, but the operator owns the controller, its credentials and its storage. The managed extension uses trusted access and Entra identities instead of a stored secret. |
| Reuse `bv-<project>-prod` | Its soft delete cannot be turned off, so a deleted instance would block teardown for the retention window (finding 6 in the README). |

## Consequences

- Same-region restore only, crash-consistent. Postgres replays its WAL on start.
  Not regional DR, not application-consistent.
- The recovery point's `recoveryPointTime` is later than the data it holds (about
  2.5 minutes on 2026-10-29). Data loss is measured from the highest recovered
  write, never from the timestamp.
- The extension identity needs Storage Account Contributor on its storage account
  (listKeys) in addition to the Storage Blob Data Contributor the Learn
  prerequisites table lists.
- Proven 2026-10-29: namespace deleted 17:43:35, restore job 219s, Postgres Ready
  316s and writes resumed 405s after the delete. Last durable write 3301, recovered
  3007 with no gaps, 294 writes lost. Flux resumed Compliant with no diff.
- Revisit for cross-region recovery: that needs the vault tier, so disks without a
  disk encryption set or a different key strategy.
