# ADR: dedicated, hardened state backend

Status: accepted, 2026-10-06.

## Context

Every root kept state in `sttfbejordprojs8557`, a storage account created by
hand and shared with other projects. It was not in Terraform, and its live
settings fell short of what this landing zone enforces on everything else: blob
versioning off, blob and container soft delete off, no delete lock, shared key
access on, Microsoft-managed keys. An overwritten or deleted state blob had no
version to roll back to. The AWS and GCP zones each own their state backend;
Azure was the odd one out.

## Decision

`bootstrap/` creates a backend that belongs to this landing zone alone, in
`rg-alz-tfstate`, and every root's backend and `terraform_remote_state` block
points at it with `use_azuread_auth = true`.

| Control | Implementation |
|---|---|
| Destruction protection | `prevent_destroy` on the account and vault; `CanNotDelete` lock on the resource group; `make destroy` never touches `bootstrap/` |
| Versioning and recovery | Blob versioning; 30-day blob and container soft delete; noncurrent versions expire after 90 days |
| Encryption | Customer-managed key (`cmk-alz-tfstate`) in a dedicated RBAC vault with purge protection, reached through a user-assigned identity; 90-day rotation; infrastructure (double) encryption |
| Access and transport | HTTPS only, TLS 1.2, no public blobs, shared keys and local users disabled, so every request needs an Entra ID token and a Storage Blob Data role |
| Locking | The azurerm backend's native blob lease |

## Trade-offs

**Network default is Allow, behind identity.** With shared keys off, there is no
key or SAS that works without Entra ID, so identity is the perimeter. An IP
allowlist on a dynamic home IP already locked the base Key Vault
(`ForbiddenByFirewall`) mid-session; on the state account the same failure
would block every plan in every root. `network_default_action = "Deny"`
switches the allowlist on when the operator has a stable egress IP. A private
endpoint would need a VNet and DNS zone that outlive every session, so it is
out of scope.

**No read logging.** Blob diagnostics need a standing Log Analytics workspace,
and the landing zone's workspace is destroyed between sessions. Versioning and
soft delete are the recovery controls; Activity Log still records control-plane
changes.

**Software key, not HSM.** Same reasoning as the landing zone CMK: an HSM key
needs a Premium vault.

## Migration

`scripts/migrate-state-backend.sh`. The first bootstrap apply runs against the
old account through `-backend-config` overrides, because the new account does
not exist yet. Then each root is initialised on the old backend, its resource
count is recorded, the state is copied with `init -migrate-state`, and the
count on the new backend must match. Old blobs are left in place as the
rollback.

## Cost

Under $1/month standing: a few KB of GRS storage, plus about $1 per scheduled
key rotation (4 a year).
