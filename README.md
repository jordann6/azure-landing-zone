# Azure Landing Zone

A standalone, best-practice Azure landing zone built with bespoke Terraform: a
management-group hierarchy with preventive (Deny) policy guardrails and the
built-in CIS initiative, a hub-and-spoke network with centralized Azure Firewall
egress inspection and Bastion-only admin access, private endpoints, central
logging with Defender for Cloud, a CMK-backed Key Vault, and least-privilege Entra
identity with just-in-time elevation to Prod. It is one of three isolated landing
zones (AWS, Azure, GCP) in this portfolio; the three do not communicate.

## Architecture

![Architecture](docs/architecture.png)

## The problem it solves

A subscription with no landing zone lets anyone create anything, anywhere, with no
tags, public IPs on demand, admin ports open to the internet, secrets in code, and
no central log of what happened. This repo is the governed foundation a workload
lands **into**: the guardrails are attached at the hierarchy so every current and
future resource inherits them, the network forces all egress through one inspected
chokepoint, the only admin path is Bastion, and the whole thing is scored against
the CIS Azure Foundations Benchmark. It stands up, proves its guardrails deny, and
tears down under a fixed budget.

## How Azure differs from the AWS and GCP zones

Same design contract, three different control planes:

- **Hierarchy**: Azure uses **management groups** (+ resource groups in this
  single-subscription demo) where AWS uses **Organizations OUs/accounts** and GCP
  uses **folders/projects**. The intended subscription-per-tier split is documented
  in [access-model.md](docs/access-model.md).
- **Preventive guardrails**: **Azure Policy with Deny effects** and the built-in
  **CIS initiative**, where AWS uses **SCPs** and GCP uses **org policies** applied
  at the org root.
- **Egress inspection**: **Azure Firewall + a UDR** forcing `0.0.0.0/0` through it,
  where AWS uses a **Network Firewall in an inspection VPC off a Transit Gateway**
  and GCP uses **Cloud NAT + hierarchical firewall policies**.
- **Admin path**: **Azure Bastion** (no public VM IPs), where AWS uses **SSM
  Session Manager** and GCP uses **IAP-only SSH**.
- **Identity/JIT**: **Entra ID groups + PIM**, where AWS uses **IAM Identity Center
  permission sets** and GCP uses **Cloud Identity + IAM Conditions**.

## What gets built, by tier and pillar

**Governance (free layer).**
- Management-group tree: root → Platform, Workloads (Dev, Test, Prod), Sandbox
  (`terraform/main.tf`). The subscription is associated to Workloads so policy
  inherits down.
- Preventive **Deny** policies at the hierarchy: deny public IP, allowed locations
  (tighter at Prod), and required tags (`owner`, `cost_center`, `environment`,
  `data_classification`) (`terraform/policies.tf`). The deny-public-IP assignment
  excludes the hub resource group (`not_scopes`), where the firewall and bastion
  legitimately hold public IPs: in the intended multi-subscription design the hub
  sits under Platform and is out of scope, but this single-subscription demo
  associates the whole subscription to Workloads, so the hub needs an explicit
  carve-out while every workload spoke stays denied.
- The built-in **CIS Microsoft Azure Foundations Benchmark** initiative assigned at
  root, scored in Defender for Cloud. See [cis-mapping.md](docs/cis-mapping.md).

**Identity.**
- Seven least-privilege Entra persona groups bound at MG scope; **no standing write
  to Prod** (platform engineers are PIM-eligible for Contributor, JIT only)
  (`terraform/identity.tf`, [access-model.md](docs/access-model.md)). PIM eligibility
  needs an Entra ID P2 license, so a tenant without P2 deploys with `enable_pim =
  false`: the persona groups and MG-scoped RBAC still apply, and the JIT-to-Prod
  wiring stays in `identity.tf` behind the flag for a P2 tenant.

**Networking (hourly, flag-gated).**
- Hub VNet `10.0.0.0/16` with correctly named/sized reserved subnets.
- **Azure Firewall** (Standard, threat-intel Deny) with a route table forcing every
  spoke's `0.0.0.0/0` through it (`terraform/firewall_azure.tf`).
- **Azure Bastion** as the only admin path (`terraform/bastion.tf`).
- **Private endpoints + private DNS** for the Key Vault (`terraform/private_endpoints.tf`).
- Three tier spokes (dev `10.1`, test `10.2`, sandbox `10.4`), each peered to the
  hub with a **default-deny NSG** on its workload subnet (`terraform/network.tf`,
  `terraform/modules/landing-zone`). The prod tier (`10.3`) is owned by the separate
  workload root (see below), which stands up the prod VNet and peers it to this hub,
  so the base does not vend a prod spoke.
- An **opt-in FortiGate NVA** is the alternative third-party egress path
  (`terraform/firewall.tf`), mutually exclusive with Azure Firewall.

**Logging, encryption, cost.**
- Central **Log Analytics** workspace with diagnostic settings on the hub VNet and
  Key Vault; **Defender for Cloud** free CSPM renders the CIS assessment
  (`terraform/monitoring.tf`).
- **Key Vault** with purge protection + soft delete + default-Deny network ACL, and
  a **CMK with a rotation policy** (`terraform/keyvault.tf`).
- A monthly **budget** with actual + forecast alerts (`terraform/budgets.tf`).

## Workload paved road (prod tier, `workload/`)

A separate Terraform root (`workload/`, its own state) is the prod paved road, the
hourly-billed layer that lands in the prod tier (`10.3`) and is deployed for a demo
then destroyed on its own. It mirrors `aws-scp-governance/workload` (EKS to AKS),
reading the base landing zone over remote state (the hub VNet, the firewall private
IP, the Log Analytics workspace) and peering the prod VNet to the hub.

| Control | What it is |
|---|---|
| Cluster | **Private AKS**: no public control plane, egress only through the hub firewall (`outbound_type=userDefinedRouting`), CMK envelope encryption of etcd secrets (Key Vault KMS), CMK node disks (disk encryption set), Entra RBAC with local accounts disabled, control-plane audit logs to Log Analytics (`workload/aks.tf`). |
| Pod identity | **Workload identity** (OIDC), the IRSA analog: the External Secrets Operator service account federates to an Entra identity scoped to read only the DB secret (`workload/workload-identity.tf`). |
| Data | **PostgreSQL Flexible**, zone-redundant HA, VNet-injected (private), CMK storage, Entra auth, credential in Key Vault (`workload/postgres.tf`). |
| Registry | **ACR Premium**: no public access, CMK, private endpoint, MCR pull-through cache, the only sanctioned image source (`workload/acr.tf`). |
| Private access | Private endpoints + private DNS for ACR and Key Vault, so the private cluster pulls images and reads secrets with no internet path (`workload/private-endpoints.tf`). |
| Backup | Geo-redundant Backup vault with soft delete, protecting the database (`workload/backup.tf`). |
| Network | Prod VNet `10.3`, no public IP/NAT, egress `0.0.0.0/0` to the hub firewall, app/data NSGs (`workload/network.tf`, `workload/segmentation.tf`). VNet flow logs are deferred until the azurerm v4 upgrade. |

Because a private AKS cluster with UDR egress cannot provision unless the firewall
permits AKS's required destinations, `workload/aks-egress-firewall.tf` attaches an
`AzureKubernetesService` FQDN-tag rule collection to the base firewall policy. This
is the Azure analog of the hub firewall's domain allowlist that fronts the private
EKS cluster on the AWS side.

Deploy it after the base (with the hourly firewall up): `make deploy-workload`, tear
it down first with `make destroy-workload`.

## Deploy

Credentialed applies run locally (`az login`), plan-before-apply. The deploy is two
steps so the free layer stands up first and the hourly network layer is a separate,
explicit confirmation.

```bash
az login && az account set --subscription <id>

# Copy the example, set deployer_ip_cidrs to your workstation IP so the CMK can be
# created (curl -s https://ifconfig.me), then:
cp terraform/example.tfvars terraform/terraform.tfvars   # gitignored

# 1) Free layer: MGs, Deny policies, CIS, identity, logging, Key Vault CMK
make deploy            # apply with enable_firewall/bastion/private_endpoints = false

# 2) Hourly layer, after reviewing the plan and cost:
make deploy-network    # Azure Firewall + Bastion + UDR + private endpoints
```

Through the `!` bash line (no interactive prompts) use the same commands with
`-auto-approve` and ABSOLUTE `-chdir` paths, e.g.
`terraform -chdir=/Users/jordannelson/azure-landing-zone/terraform apply -auto-approve -var enable_firewall=false ...`.

## Test (prove the guardrails deny)

```bash
make test    # scripts/test-guardrails.sh
```

It does not just check that apply succeeded. It asserts that Azure **refuses**: a
public IP (deny_public_ip), a resource group in a disallowed location
(allowed_locations), and an untagged resource group (require-tag), each returning
`RequestDisallowedByPolicy`; that the CIS initiative is assigned; and that Bastion
is the admin path. It prints pass/fail per check and cleans up anything it created.

## Destroy

```bash
make destroy    # terraform destroy, then scripts/verify-teardown.sh
```

`verify-teardown.sh` fails if any hourly-billed resource (Firewall, Bastion,
Standard public IPs, VMs, private endpoints) is still alive.

## Cost and teardown traps

- **Standing after destroy**: ~$1/mo. The Key Vault CMK survives in a soft-deleted
  state (purge protection holds it for the soft-delete window) by design;
  everything else is torn down.
- **Demo window** (flags on, ~2 hours): Azure Firewall Standard ~$1.25/hr, Bastion
  Basic ~$0.19/hr, private endpoints ~$0.01/hr each, Log Analytics ~free at demo
  volume. Roughly $3, under the portfolio's ~$7 ceiling.
- **Traps**: Azure Firewall and any Gateway take **10-30 min** to delete; the
  resource group goes last. `enable_firewall` and `enable_fortigate` are mutually
  exclusive (both force `0.0.0.0/0` through a different next hop). Azure DDoS
  Network Protection and paid Defender plans are designed-for but off (cost).

## FortiGate-VM egress (opt-in alternative)

Instead of Azure Firewall, the hub can route spoke egress through a **Fortinet
FortiGate-VM** NVA (`enable_fortigate=true`, and set `enable_firewall=false`). It
lives in dedicated `snet-fw-untrust` / `snet-fw-trust` subnets (a third-party NVA
cannot share `AzureFirewallSubnet`) and forces every spoke's default route through
its trust interface. Accept the marketplace terms once, then apply:

```bash
az vm image terms accept --publisher fortinet --offer fortinet_fortigate-vm_v5 --plan fortinet_fg-vm
terraform -chdir=terraform apply \
  -var enable_firewall=false -var enable_fortigate=true \
  -var fortigate_admin_password='<StrongPassw0rd!>'
```

This path was previously validated live on Azure (eastus): the FortiGate booted on
`Standard_F2s_v2`, drew a public IP on untrust, and the spoke route tables confirmed
`0.0.0.0/0 -> 10.0.5.4` (VirtualAppliance) on the workload subnets, then torn down
clean. Watch the `Total Regional vCPUs` quota if you also run the VM-Series lab in
[azure-vm-hardening](https://github.com/jordann6/azure-vm-hardening).

## CI

Static gates run through the shared [platform-guardrails](https://github.com/jordann6/platform-guardrails)
toolkit (`.github/workflows/guardrails.yml` → `tf-ci.yml@v1.3.0`): full-history
gitleaks, `fmt` + `validate`, lockfile-committed assertion, tflint, Checkov, and
Trivy config. The credentialed `apply` / `destroy` / `ttl-guard` workflows are
wired but **inactive**: the shared reusable workflows authenticate to AWS only, so
until they gain an `azure/login` OIDC path, Azure applies run locally. Deliberate
Checkov/Trivy trade-offs (public Key Vault for CMK creation, Standard-tier firewall
without IDPS, software-protected key) are inline-skipped with reasons in the code.

## Docs

- [docs/cis-mapping.md](docs/cis-mapping.md): CIS control → Terraform resource, with honest gaps.
- [docs/access-model.md](docs/access-model.md): persona-by-scope matrix, PIM/JIT, single-sub design.
- [docs/accelerator-vs-bespoke.md](docs/accelerator-vs-bespoke.md): why bespoke modules over the ALZ accelerator.

## Tech stack

- **Terraform** `>= 1.6`, `azurerm ~> 3.100`, `azuread ~> 2.50`, Azure Storage state backend
- **Azure Management Groups + Azure Policy** (Deny) + built-in CIS initiative
- **Azure Firewall + Bastion + UDR + Private Endpoints/DNS** hub-spoke inspection
- **Log Analytics + Defender for Cloud**, **Key Vault + CMK rotation**
- **Entra ID** persona groups + MG-scope RBAC + PIM
- Reusable `landing-zone` spoke-vending module
