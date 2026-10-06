# Azure LZ Workload (AKS paved road) — Handoff, updated 2026-09-27

## Status: DEPLOYED, verified, and DESTROYED 2026-09-27. Committed (b38d461) on `phase3-azure`.

The base LZ + workload paved road landed end to end in **centralus** (ran at ~$2.1-2.3/hr
while up), were verified green, then destroyed. One remnant remains: the backup vault in
`rg-alz-prod-workload` (see "Known teardown remnant" below).

Verified green while deployed (2026-09-27):
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

- **Final cleanup** after the ~14-day backup soft-delete window: re-run the workload destroy (see remnant below).
- **VNet flow logs** — still deferred until the azurerm v4 bump.
- Minor: unused `kubernetes_version` var in `workload/variables.tf`.

## Teardown (run by Jordan via `!`, absolute paths, -auto-approve)

```
terraform -chdir=/Users/jordannelson/azure-landing-zone/workload destroy -auto-approve
terraform -chdir=/Users/jordannelson/azure-landing-zone/terraform destroy -auto-approve -var enable_bastion=false -var enable_private_endpoints=false
```
Residual by design: soft-deleted Key Vaults (~$1–2/mo). If a workload resource wedges the destroy,
`az group delete -n rg-alz-prod-workload --yes` then re-run the base destroy.

### Known teardown remnant (2026-09-27): backup vault soft-delete
The workload destroy left 3 resources in state — `azurerm_data_protection_backup_policy...prod`,
`...backup_vault.prod`, `azurerm_resource_group.prod` — because the deleted PG backup instance
`bi-alz-postgres` went to **soft-deleted** state and the policy can't delete while associated with it
(`UserErrorPolicyAssociatedWithSoftDeletedItems`). The vault requires **Always-On soft delete**
(`--soft-delete-state Off` is rejected as `DppAlwaysOnSoftDeleteStateMandatory`), and there is no
purge command, so the soft-deleted instance can't be removed on demand — it auto-expires with the
14-day soft-delete retention. Cost is ~$0 (no standing vault charge; the short-lived instance holds
negligible/zero backup storage). **Final cleanup:** after the retention window, re-run
`terraform -chdir=workload destroy -auto-approve` (or `az group delete -n rg-alz-prod-workload --yes`)
to clear the vault + policy + RG and empty the workload state. Only `bv-alz-prod` remains in the RG;
AKS/PG/ACR/VNet/KV are all gone (workload compute/DB billing stopped).

## Environment facts

- Personal subscription and tenant (IDs intentionally not recorded in the repo; see `az account show`).
- Elevate access done (User Access Administrator at `/`). No Entra ID P2 → base `enable_pim = false`.
- Workstation public IP goes in `deployer_ip_cidrs` in both (gitignored) tfvars; it changes, so refresh it with `curl -4 ifconfig.me`.
- Backend (at the time): `rg-tfbackend-jordprojs` / `sttfbejordprojs8557` / container `tfstate`. Since moved to the dedicated `rg-alz-tfstate` / `stalztfstatejn` backend (bootstrap/). Base key
  `azure-landing-zone/dev.terraform.tfstate`, workload key `azure-landing-zone/workload.terraform.tfstate`. azurerm 3.117.1.
