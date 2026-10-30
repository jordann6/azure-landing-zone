# Case Study: Azure Landing Zone + Workload Paved Road

## Problem

Governance applied after workloads exist is negotiation. Governance applied to a
management group before the first subscription lands there is just the
environment. That distinction decides whether a policy is a guardrail or a
ticket.

But a governed foundation is only half the story. A paved road is only real if a
workload can actually land on it and inherit the controls without hand-wiring
each one. So this project is two layers: a **base landing zone** that establishes the governance a
subscription inherits, and a **prod workload** (private AKS plus a managed
database) that deploys onto it as the reference paved road.

## Architecture

Two Terraform roots against one subscription.

- **Base** (`terraform/`): a management group tree under the tenant root
  (Platform, Workloads, Sandbox, with dev/test/prod beneath Workloads), the
  subscription placed under Workloads, custom Azure Policy definitions plus the
  CIS Azure Foundations initiative assigned at that scope, and a hub VNet
  (10.0.0.0/16) with reserved Firewall/Gateway/Bastion subnets and an Azure
  Firewall for centralized egress inspection.
- **Workload** (`workload/`): a prod VNet (10.3.0.0/16) peered to the hub, a
  private AKS cluster, a zone-redundant HA PostgreSQL Flexible Server, ACR, and
  the identity/KMS/backup plumbing around them. It reads the base outputs
  (firewall policy id, hub VNet) over remote state and attaches its own egress
  rules to the hub firewall.

![Base landing zone](architecture.png)

![Workload paved road](workload-architecture.png)

## What was built

- **Governance that attaches to placement.** Moving the subscription into the
  Workloads management group means every policy assigned there applies
  automatically: require owner tag, deny public IPs, allowed locations, and
  required cost-center/environment/data-classification tags, plus the CIS
  initiative. A stricter Prod single-region policy is assigned at the Prod group,
  but no subscription sits there in this demo, so it binds nothing yet.
- **Private AKS, no public control plane.** `private_cluster_enabled`, OIDC
  issuer and workload identity on, local accounts disabled, and
  `outbound_type = userDefinedRouting` so all egress leaves only through the hub
  Azure Firewall (the workload contributes the AKS-required FQDN allowlist to the
  hub policy).
- **etcd CMK over a private Key Vault.** Kubernetes secrets are envelope-encrypted
  with a customer-managed key reached over a Key Vault private endpoint; the vault
  stays default-Deny. Node OS disks use a separate CMK via a disk encryption set.
- **Zone-redundant HA PostgreSQL.** VNet-injected into a delegated subnet,
  customer-managed-key encrypted, Entra auth enabled, primary in zone 1 with a
  standby in zone 2, protected by a geo-redundant Data Protection backup vault.
- **Least-privilege identities.** ACR behind a private endpoint, External Secrets
  gets a federated workload identity, and the AKS control-plane identity carries a
  custom role scoped to exactly the Key Vault private-endpoint approval actions it
  needs, nothing broader.

## Engineering decisions worth calling out

**Private KMS forces a chain of requirements the platform enforces rather than
documents.** Setting the AKS etcd KMS `key_vault_network_access` to `Private` is
rejected outright with `Vnet integration should be enabled when KeyVault network
access is Private`. Enabling **API Server VNet Integration** (a delegated
`snet-apiserver` subnet) clears that, but then AKS stands up its *own* managed
private endpoint to the vault and fails with `LinkedAuthorizationFailed` because
the cluster identity can create the endpoint but cannot approve the connection,
a permission no built-in Crypto User or Network Contributor role grants. The fix
is a custom role with exactly
`Microsoft.KeyVault/vaults/privateEndpointConnectionProxies/*` and
`.../PrivateEndpointConnectionsApproval/action` on the vault, not weakening the
vault to public. Each error was the platform telling you the next required piece.

**Zone-redundant Postgres HA needs the NSG to allow itself.** HA replicates
between a primary and a standby inside one delegated subnet. A data NSG that
allows 5432 only from the app and AKS subnets and denies the rest silently blocks
the standby from reaching the primary, and the server create fails with
`VnetReplicationToPrimaryNetworkBlocked`. The fix is an explicit intra-subnet
5432 allow above the catch-all deny (outbound is already permitted by the default
`AllowVnetOutBound`).

**The backup role has to be assigned where its actions apply.** The
`PostgreSQL Flexible Server Long Term Retention Backup Role` includes
`Microsoft.Resources/subscriptions/resourceGroups/read`, but assigned at the
*server* scope that action has no effect, so configuring the backup fails with
`AuthorizationFailed` on RG read. Moving the assignment to the resource-group
scope, still narrow, resolves it.

**Region is a capacity decision, not just a config value.** PostgreSQL Flexible
Server is capacity-restricted in the original region for this subscription
(`list-skus` returns an empty version list), so the whole landing zone was moved
to centralus, which has the versions plus zone-redundant HA. The move touched two
tfvars, the two location defaults, and the `allowed_locations` guardrail list.
On 2026-10-06 centralus then refused every new AKS cluster for this
subscription (`AKSCapacityHeavyUsage`), whether private or public, Free or
Standard tier, with or without API Server VNet Integration. Private KMS needs
VNet integration, so the config stayed and the region moved. One-node probes with
the exact private, VNet-integrated config succeeded in six other US regions, so
the v4 proof ran in eastus2 (zone-redundant Postgres supported, already in
`allowed_locations`). The base and workload moved together to keep the hub and
its spoke in one region, and a `resource_group_name` override kept the new
workload group clear of the old one, which still holds a soft-deleted backup
instance.

**Management-group policy propagation is eventually consistent.** On a freshly
built hierarchy, child-scope policy assignments 400 with "policy definition is out
of scope" for up to ~25 minutes until the tree and definition visibility
propagate. The base apply is simply re-run once it settles; the code is correct.

**Drift pinned, not fought.** Azure adds a `Microsoft.Storage` service endpoint to
the Postgres subnet, assigns HA zones, and applies a default node-pool
`max_surge`. Each is declared explicitly (service endpoint, `zone`/
`standby_availability_zone`, `upgrade_settings`) so plans stay clean instead of
churning every run.

## What it deliberately does not do

- **One subscription.** The AWS zone isolates tiers with accounts and the GCP zone
  with projects. With no EA or MCA to vend subscriptions, Azure uses management
  groups and resource groups, so a subscription-level mistake reaches every tier.
- **No threat-detection service.** Detection is the free Defender tier, change
  alerts on every guardrail, and a full audit trail. Paid Defender plans and
  Sentinel are costed and left off ([ADR-0004](adr/0004-detection-tier.md)).
- **Observability is not a retained baseline.** It cannot outlive the base, because the workspace is destroyed with it.

Flow logs, the observability root, the secrets root, and AKS and ACR on azurerm
4.x were proven in deploy-test-destroy sessions on 2026-10-06 (see the last
section). The parity table in the README says which items are proven.

## Verification and teardown

Verified against real Azure through the control plane, not the plan file: private
AKS nodes `Ready` with etcd KMS enabled over the KV private endpoint, PostgreSQL
HA `Healthy` (primary zone 1 / standby zone 2), and the backup instance
`ProtectionConfigured`. These results cover the earlier workload demo. Compute
and network resources were removed, but a protected backup vault remains during
its recovery window alongside soft-deleted Key Vaults. This is not a zero-invoice
claim.
Deploy-demo-destroy keeps the reference reproducible for roughly the price of a
couple of hours of runtime (~$2/hr while up) rather than a standing bill.

## Compute baseline proven live

The local compute changes add approved-gallery, VM-size, and host-encryption
controls, guest baseline auditing, and periodic update assessment. AKS retains
its managed Ubuntu image with SecurityPatch and weekly maintenance settings
checked statically. A separate `compute/` root defines a private gallery-backed
management VM and weekly security patches. Packer uses a dedicated build group
and narrow, expiring bootstrap exemptions.

On 2026-10-05, the Packer image passed 28 guest hardening checks after reboot.
A new private management VM booted from that image passed all 28 checks through
Azure Run Command. The 16-check guardrail suite passed, including three isolated
denials for an unapproved image, forbidden size, and missing host encryption.
The first VM had revealed that Apport resets `fs.suid_dumpable` during boot;
the corrected role removes Apport and the image pipeline checks after reboot.
This proves the implemented CIS-informed controls, not full benchmark compliance.
The supervised session excludes Firewall, Bastion, AKS, and PostgreSQL. Its
teardown removes compute, Packer-created image storage, and the free base while
preserving the existing backup vault's protected recovery data.

## Parity gap-close proven live

On 2026-10-06 the zone moved to azurerm 4.x and gained VNet flow logs, an
observability root and a secrets root. A deploy-test-destroy session ran them
against real Azure:

- **Flow logs:** 9 of 9 checks pass. Hub and prod flow logs write to a
  CMK-encrypted, default-Deny storage account through the trusted-service bypass,
  and Traffic Analytics returned 190 `NTANetAnalytics` rows.
- **Observability:** 4 of 4 checks pass. The change alerts exist and fire.
- **Secrets:** 11 of 11 checks pass. The scanner identity holds Key Vault Reader,
  `checkAccess` shows metadata `Allowed` and `getSecret` `NotAllowed`, a real
  secret value read as a Reader principal returns 403, the seeded no-expiry secret
  meets the finding criterion, and a NearExpiry audit event reached the workspace
  and the alert fired. The 403 also triggered the forbidden-read alert, and that
  email arrived, which proves the detection path end to end.
- **Backup instance:** the azurerm resource returned 406 on create and delete, so
  it is an `azapi` resource. Create and destroy both worked.
- **Teardown:** `make destroy` then `verify-teardown.sh` passed. The backup vault
  and soft-deleted Key Vaults remain by design.
- **AKS and ACR on azurerm 4.x (4.81.0), eastus2:** AKS `Succeeded`, 2 of 2
  nodes Ready (checked through `az aks command invoke`, the cluster is private),
  API Server VNet Integration on the delegated subnet, etcd KMS with
  `keyVaultNetworkAccess = Private`, OIDC issuer and workload identity enabled,
  egress by user-defined routing to the hub firewall. ACR Premium with public
  access disabled, an approved private endpoint, CMK encryption, and the
  `mcr-cache` rule `Succeeded`. After apply, `terraform plan -detailed-exitcode`
  returned no changes for both the workload and the base, which is the rename
  proof. `make destroy` then `verify-teardown.sh` passed again.

### Not proven

- The Expired variants of the secrets alert are matched by name and not observed.
- **Warm standby is not an LZ-wide capability.** The member portal has a measured
  two-region setup (Front Door shift 83.9 s, SQL failover group planned failover
  RTO 7.3 s and RPO 0), but only planned failovers were drilled. The prod tier has
  in-region zone-redundant HA and a geo-redundant backup vault, and a policy pins
  Prod to one region.

## SRE layer proven live

A paved road that deploys is not the same as one an on-call engineer can run. Two
flags on the workload root, both off by default, add the operating layer:
`enable_sre_demo` puts Flux on the cluster, reconciling `gitops/` from this repo
(a .NET 10 service with a load generator, Grafana, and a Postgres StatefulSet on
CMK disks), sends managed Prometheus metrics to an Azure Monitor workspace, and
evaluates SLO recording and multiwindow burn-rate rules there, paging through the
base action group. `enable_aks_backup` adds an operational-tier AKS Backup vault
for the stateful namespace. Images are pinned by digest, and every secret comes
from Key Vault through the CSI driver with one workload identity per consumer.

![SRE demo layer](sre-demo-architecture.png)

Two design calls carry most of the weight. Rules run in the Azure Monitor
workspace, not in the cluster, so the page still fires when the cluster is what
broke ([ADR-0005](adr/0005-sre-metrics-path.md)). Backup uses the operational tier
in its own vault with soft delete off, because the vault tier rejects disks with
a disk encryption set and the retained Postgres vault would block teardown for its
retention window ([ADR-0006](adr/0006-aks-backup-operational-tier.md)).

On 2026-10-29 in eastus2, a drill session ran each scenario against the live
cluster:

- **GitOps:** a manual `kubectl scale` from 3 to 1 was reverted by Flux in 29
  seconds, timed from the cluster clock and the kustomize-controller's
  managedFields entry. A commit raising the load generator from 20 to 25 rps was
  live in 63 seconds with no kubectl.
- **SLO:** a 50% fault injected at 17:02:36 fired `SloFastBurn` at 17:08:04
  (evaluated 0.077 against a 0.072 threshold), and the page email arrived by
  17:10. With the fault removed, the alert resolved at 17:23:02.
- **Restore:** the `slo-data` namespace was deleted at 17:43:35 while a writer
  was inserting rows. The restore job took 219 seconds, Postgres was Ready at 316
  and writes resumed at 405. The last durable write was 3301 and the restore held
  3007 with no gaps, so 294 writes were lost. That figure comes from the rows, not
  the recovery point's timestamp, which was 2.5 minutes later than the newest data
  it held. Flux resumed Compliant with no diff.

The session also found what the static gates could not. A fresh cluster was
denied its own KMS key until the control-plane identity got the built-in Reader
role and a propagation wait. The kubelet had no AcrPull, which the earlier proof
never exercised because it never pulled an app image. Teardown deleted the hub
peerings and the Key Vault private endpoint before the cluster, so nodes lost
egress mid-destroy and the Flux and backup deletes hung for 30 minutes; the
cluster now depends on its whole network path, and a credential-free
`terraform graph` check in CI fails on any of 52 missing ordering edges. And the
firewall's FQDN allowlist was mostly moot: network rules are evaluated first, and
a broad `AzureCloud` rule was carrying Monitor ingestion, so it is now the
documented `AzureMonitor:443`.

A second, shorter session that evening proved both fixes. The 98 workload
resources were destroyed in 23 minutes in dependency order with no manual step:
the Flux configuration in 1m03s and the backup instance in 1m54s, then the
cluster in 6m46s, and only then the peerings and private endpoints. The narrowed
rule carried 2,025 connections while Flux, Container Insights, managed
Prometheus, Azure Policy and an on-demand backup (4m06s) all worked. That session
found two more. Three nodes still left the backup agent short of CPU (it requests
520m and the largest free slice was about 440m), so the default is now four. And
the backup instance checks its storage permissions once at creation and never
retries, so it now waits five minutes after its role assignments, the same
pattern the cluster already used. `verify-teardown.sh` passed after both
sessions.

The full list of findings is in the README ("What the live runs found", items 9
to 23), with the SLO spec in [slo.md](slo.md), the runbooks in
[runbooks/](runbooks/) and the priced session plan in
[sre-session.md](sre-session.md). Session costs are estimates, about $7 to $9.50
for the drill session and $6 to $7.50 for the proof session, until Cost
Management posts.

### Not proven

- **Cross-region restore.** The operational tier restores in the same region
  only, and the result is crash-consistent, not application-consistent. Postgres
  replays its WAL on start.
- **Paging beyond email.** Sev 1 and Sev 3 both deliver by email; an on-call
  rotation or paging service would be an action group change.
- **The Grafana UI.** Grafana has no public endpoint and viewing it needs Bastion
  Standard. The drills check its data source and run the dashboard's queries
  through its API instead.
- **Logs.** There is no log aggregation stack in the cluster; Container Insights
  is the log path.
