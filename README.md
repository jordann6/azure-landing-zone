# Azure Landing Zone

An enterprise-grade Azure landing zone built with Terraform. Establishes the governance foundation that workload subscriptions inherit: a management group hierarchy, policy-as-code guardrails, and a hub-spoke network with a reusable spoke-vending module. Every spoke is provisioned by calling one module block.

## Architecture

![Architecture](docs/architecture.png)

| Layer | Component | Role |
|---|---|---|
| Governance | **Management group hierarchy** | Four-level tree (org root → Platform, Workloads, Sandbox) |
| Policy | **Azure Policy (3 definitions)** | Require owner tag · deny public IPs · allowed locations |
| Connectivity | **Hub VNet** (10.0.0.0/16) | Reserved subnets for Firewall, Gateway, Bastion; active management subnet + NSG |
| Connectivity | **Spoke VNets** (10.1–2.0.0/16) | Platform and Sandbox spokes, each peered to hub in both directions |
| IaC | **Terraform module** (`modules/landing-zone`) | Vends a new spoke (resource group + VNet + peering) with a single module call |

## Management group hierarchy

```
Tenant Root Group
└── jordann6  (mg-jordann6)
    ├── Platform   (mg-jordann6-platform)
    ├── Workloads  (mg-jordann6-workloads)  ← subscription lives here
    └── Sandbox    (mg-jordann6-sandbox)
```

The subscription is moved into `mg-jordann6-workloads` so all three policy assignments apply automatically to every resource in this subscription.

## Policy guardrails

Policies are defined as Custom definitions at the Workloads management group and assigned at that same scope.

| Policy | Effect | Condition |
|---|---|---|
| Require owner tag | Audit | Resource groups missing an `owner` tag |
| Deny public IP creation | Audit | Any `Microsoft.Network/publicIPAddresses` resource |
| Allowed locations | Audit | Resources not in `eastus` or `eastus2` |

Effects are set to `Audit` for demo deployment. In a production pipeline these would be `Deny`, applied in a separate governance stage before workload provisioning begins.

## Hub-spoke network

```
Hub VNet  10.0.0.0/16
├── AzureFirewallSubnet    10.0.0.0/26   (reserved — /26 minimum for Azure Firewall)
├── GatewaySubnet          10.0.1.0/27   (reserved — /27 minimum for VPN/ER Gateway)
├── AzureBastionSubnet     10.0.2.0/26   (reserved — /26 minimum for Azure Bastion)
└── snet-management        10.0.3.0/24   (active, NSG blocks inbound internet)

Spoke: Platform   10.1.0.0/16  →  snet-workloads  10.1.0.0/24
Spoke: Sandbox    10.2.0.0/16  →  snet-workloads  10.2.0.0/24
```

Reserved subnets carry the names Azure requires (`AzureFirewallSubnet`, `GatewaySubnet`, `AzureBastionSubnet`) and are sized to minimums, so the services can be activated later without re-addressing.

## Landing-zone vending module

Adding a new spoke takes one module call:

```hcl
module "spoke_dev" {
  source = "./modules/landing-zone"

  name                    = "dev"
  project                 = var.project
  location                = var.location
  address_space           = ["10.3.0.0/16"]
  workload_subnet_prefix  = "10.3.0.0/24"
  hub_vnet_id             = azurerm_virtual_network.hub.id
  hub_vnet_name           = azurerm_virtual_network.hub.name
  hub_resource_group_name = azurerm_resource_group.hub.name
  tags                    = local.tags
}
```

The module creates the spoke resource group, spoke VNet, workload subnet, and both directions of the VNet peering so the hub and spoke can route to each other immediately.

## Deploy

```bash
cd terraform
terraform init
terraform apply
```

## Verify

```bash
# Confirm management group hierarchy
az account management-group list --query "[].{name:name, displayName:displayName}" -o table

# Confirm subscription is under Workloads MG
az account management-group show --name mg-jordann6-workloads --expand --recurse \
  --query "children[].{type:type, name:name}" -o table

# Confirm policy assignments
az policy assignment list --scope /providers/Microsoft.Management/managementGroups/mg-jordann6-workloads \
  --query "[].{name:name, displayName:displayName}" -o table

# Confirm hub-spoke peering is Connected
az network vnet peering list --resource-group rg-alz-hub --vnet-name vnet-alz-hub \
  --query "[].{name:name, state:peeringState}" -o table
```

## FortiGate-VM hub firewall (opt-in)

Enterprises route spoke egress through a network virtual appliance in the hub.
This layer deploys a **Fortinet FortiGate-VM** into dedicated NVA subnets and
forces every spoke workload subnet's default route through its trust interface,
so all north-south traffic passes one inspected chokepoint. It is gated on
`enable_fortigate` (default `false`) so the landing zone still applies as a pure
governance demo at near-zero cost.

```
                     Internet
                        |
             pip / port1 (untrust, 10.0.4.0/24)
                        |
                [ FortiGate-VM ]
                        |
             port2 (trust, 10.0.5.4)
                        |
        ┌───────────────┴───────────────┐
   Platform spoke                   Sandbox spoke
   snet-workloads                   snet-workloads
   (0.0.0.0/0 → 10.0.5.4 via UDR)   (0.0.0.0/0 → 10.0.5.4 via UDR)
```

Placement note: a third-party NVA cannot live in `AzureFirewallSubnet`, which is
reserved for the Azure Firewall managed service. The FortiGate gets its own
`snet-fw-untrust` / `snet-fw-trust` subnets, the same reserved-subnet discipline
applied to Bastion elsewhere in this portfolio.

FortiGate-VM is a marketplace image, so accept its terms once per subscription,
then apply with the firewall enabled:

```bash
az vm image terms accept --publisher fortinet \
  --offer fortinet_fortigate-vm_v5 --plan fortinet_fg-vm

cd terraform
terraform apply \
  -var enable_fortigate=true \
  -var fortigate_admin_password='<StrongPassw0rd!>'
# outputs: fortigate_untrust_ip, fortigate_console
```

Reach the console at `https://<fortigate_untrust_ip>` and confirm spoke egress
now traverses the FortiGate. Cost: `Standard_F2s_v2` is roughly $0.085/hour plus
PAYG licensing if you use a `*_payg_*` SKU instead of BYOL, so keep it to a short
deploy-demo-destroy window. `terraform destroy` removes the firewall, its NICs,
public IP, route tables, and the added subnets.

### Validated live

Deployed and verified on Azure (eastus): the FortiGate-VM booted on
`Standard_F2s_v2` with untrust and trust interfaces, drew a public IP on untrust,
and the `rt-alz-spoke-egress` route table confirmed `0.0.0.0/0 -> 10.0.5.4`
(VirtualAppliance) on both spoke workload subnets, so all spoke egress is forced
through the firewall. Torn down clean afterward.

Note: a third-party NVA cannot share the regional-vCPU budget with a large NGFW
on a capped subscription. If you also run the Palo Alto lab in
[azure-vm-hardening](https://github.com/jordann6/azure-vm-hardening), watch your
`Total Regional vCPUs` quota, since an 8-vCPU VM-Series plus this FortiGate can
exceed a default 10-core cap.

## Teardown

```bash
cd terraform && terraform destroy
```

After destroy, Azure automatically re-associates the subscription with the tenant root group.

## Cost

VNets, subnets, NSGs, management groups, and policy assignments are free or near-zero. No VMs, no Azure Firewall, no Bastion, no Gateway. This is a provision, demo, destroy environment with negligible cost.

## Tech Stack

- **Terraform** `>= 1.6` with `azurerm ~> 3.100`, Azure Storage state backend
- **Azure Management Groups** four-level governance hierarchy
- **Azure Policy** three custom policy definitions assigned at MG scope
- **Azure Virtual Networks** hub-spoke topology with bidirectional peering
- **Terraform module** reusable `landing-zone` module for spoke vending
