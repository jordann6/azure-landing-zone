# Azure LZ Workload (AKS paved road) — Handoff, updated 2026-09-27

## Status: FULLY DEPLOYED and healthy in centralus (uncommitted). Costs ~$2.1–2.3/hr.

The base LZ + workload paved road are live end to end in **centralus** (first time the
workload has fully landed). **Nothing is committed** — all on disk on branch `phase3-azure`.

Verified green (2026-09-27):
- **AKS** `aks-alz-prod`: 2 nodes Ready (v1.35.7, private, internal-only). provisioningState
  Succeeded. etcd **KMS enabled, keyVaultNetworkAccess = Private** (CMK over the KV private
  endpoint). OIDC issuer + workload identity enabled. **API Server VNet Integration enabled.**
- **Postgres** `psql-alz-prod-4tavyj`: Ready, ZoneRedundant HA Healthy, primary zone 1 / standby 2,
  v16, CMK-encrypted, private (VNet-injected).
- **Backup**: `bi-alz-postgres` → ProtectionConfigured (geo-redundant Backup vault).
- checkov: 40 passed / 0 failed / 22 skipped. `validate` clean.

## Fixes made this session (why the earlier applies failed)

1. **Region eastus → centralus** — eastus is PG-restricted for this subscription. centralus has
   PG versions + zone-redundant HA. Edited both tfvars/variables, `allowed_locations`, examples, diagram label.
2. **Workload state reset** — the crashed destroy left 22 stale resources + an orphaned lease.
   Broke the lease, discarded `errored.tfstate`, `state rm`'d the stale resources (fresh suffix `4tavyj`).
3. **PG HA NSG** (`segmentation.tf`) — added intra-subnet 5432 allow so the zone-redundant standby
   can replicate to the primary (was `VnetReplicationToPrimaryNetworkBlocked`). Declared the
   `Microsoft.Storage` service endpoint on the data subnet to stop drift.
4. **AKS API Server VNet Integration** (`network.tf` + `aks.tf`) — Private KMS *requires* it. Added
   a `/28` `snet-apiserver` delegated to `Microsoft.ContainerService/managedClusters` + an
   `api_server_access_profile { vnet_integration_enabled = true }` block.
5. **AKS KMS private-endpoint approval** (`aks.tf`) — AKS stands up its own managed private endpoint
   to the KV for KMS; added a least-privilege **custom role** `aks-kms-pe-approver-<project>`
   (KV privateEndpointConnectionProxies + PrivateEndpointConnectionsApproval actions) on the vault.
   Was `LinkedAuthorizationFailed`.
6. **PG backup role scope** (`backup.tf`) — the LTR Backup Role includes `resourceGroups/read`, which
   only takes effect at RG scope; moved the `backup_pg` assignment from the server to the RG.
   Was `AuthorizationFailed` on RG read.
7. **Drift pins** — PG zones (`zone = "1"`, `standby_availability_zone = "2"`) and AKS default node
   pool `upgrade_settings { max_surge = "10%" }`, so plans stay clean.

## Deploy notes / gotchas seen

- MG policy hierarchy propagation on a fresh tenant took ~25 min; base policy assignments 400 with
  "out of scope" until it settles — just re-run the base apply.
- A failed AKS create leaves a Failed cluster shell NOT in TF state → `az aks delete` it before re-apply.
- Credentialed applies/destroys + backend state writes are run by Jordan via the `!` line
  (`-auto-approve`, absolute paths). Assistant runs plan/validate/read-only.

## What's left

- **Commit** (Jordan's call) — one commit on `phase3-azure`.
- **Regenerate the workload diagram** (`docs/workload.py`) — add `snet-apiserver` + centralus label.
- **Destroy** after capturing portfolio evidence (destroy-demo-destroy). Sequence below.
- **VNet flow logs** — still deferred until the azurerm v4 bump.
- Minor: unused `kubernetes_version` var in `workload/variables.tf`.

## Teardown (run by Jordan via `!`, absolute paths, -auto-approve)

```
terraform -chdir=/Users/jordannelson/azure-landing-zone/workload destroy -auto-approve
terraform -chdir=/Users/jordannelson/azure-landing-zone/terraform destroy -auto-approve -var enable_bastion=false -var enable_private_endpoints=false
```
Residual by design: soft-deleted Key Vaults (~$1–2/mo). If a workload resource wedges the destroy,
`az group delete -n rg-alz-prod-workload --yes` then re-run the base destroy.

## Environment facts

- Subscription `00000000-0000-0000-0000-000000000000` (JordanDN6, personal tenant, Global Admin).
- Elevate access done (User Access Administrator at `/`). No Entra ID P2 → base `enable_pim = false`.
- Workstation IP `203.0.113.4/32` in both tfvars.
- Backend: `rg-tfbackend-jordprojs` / `sttfbejordprojs8557` / container `tfstate`. Base key
  `azure-landing-zone/dev.terraform.tfstate`, workload key `azure-landing-zone/workload.terraform.tfstate`. azurerm 3.117.1.
