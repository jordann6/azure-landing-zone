from diagrams import Diagram, Cluster, Edge
from diagrams.azure.general import Managementgroups, Subscriptions
from diagrams.azure.network import (
    VirtualNetworks,
    Subnets,
    Firewall,
    RouteTables,
    PrivateEndpoint,
    DNSPrivateZones,
)
from diagrams.azure.compute import SharedImageGalleries, VMLinux, ImageDefinitions
from diagrams.azure.security import KeyVaults, SecurityCenter
from diagrams.azure.analytics import LogAnalyticsWorkspaces
from diagrams.azure.identity import ActiveDirectory
from diagrams.azure.managementgovernance import Alerts, Policy
from diagrams.onprem.network import Internet
from diagrams.onprem.iac import Terraform
from diagrams.custom import Custom

# The mingrammer library has no Azure Bastion node, so use the official Azure
# Bastion service icon (docs/icons/azure-bastion.png) as a custom node.
import os

BASTION_ICON = os.path.join(os.path.dirname(os.path.abspath(__file__)), "icons", "azure-bastion.png")

graph_attrs = {"fontsize": "13", "bgcolor": "white", "pad": "0.5", "splines": "ortho"}
node_attrs = {"fontsize": "11"}

with Diagram(
    "Azure Landing Zone",
    filename="docs/architecture",
    outformat="png",
    show=False,
    direction="TB",
    graph_attr=graph_attrs,
    node_attr=node_attrs,
):
    tf = Terraform("Terraform\n(IaC)")
    inet = Internet("Internet")

    with Cluster("Management Group Hierarchy  ·  CIS + HITRUST/HIPAA scoring  ·  Deny policies (inherited)"):
        mg_root = Managementgroups("jordann6\n(root)")
        mg_platform = Managementgroups("Platform")
        mg_workloads = Managementgroups("Workloads")
        mg_sandbox = Managementgroups("Sandbox")
        with Cluster("Workloads"):
            mg_dev = Managementgroups("Dev")
            mg_test = Managementgroups("Test")
            mg_prod = Managementgroups("Prod\n(stricter)")
        sub = Subscriptions("Subscription\n(single-sub demo)")
        policy = Policy("Deny: public IP, regions,\nrequired tags, data_classification,\nphi = no public network,\nVM images/SKUs/host encryption")

        mg_root >> [mg_platform, mg_workloads, mg_sandbox]
        mg_workloads >> [mg_dev, mg_test, mg_prod]

    with Cluster("Identity (Entra ID)"):
        aad = ActiveDirectory("7 persona groups\nRBAC @ MG scope; PIM optional")

    with Cluster("Hub VNet  10.0.0.0/16  ·  centralus"):
        hub = VirtualNetworks("vnet-alz-hub")
        fw = Firewall("Azure Firewall\n(Standard, threat-intel Deny)")
        udr = RouteTables("UDR 0.0.0.0/0\n-> firewall")
        bastion = Custom("Bastion\n(optional browser admin)", BASTION_ICON)
        s_pl = Subnets("snet-privatelink")
        mgmt = VMLinux("Management VM\n(private golden image; live proof)")

        with Cluster("Private access"):
            pe = PrivateEndpoint("KV private endpoint")
            dns = DNSPrivateZones("privatelink DNS zones")

    with Cluster("Compute baseline (Packer + live Run Command proof)"):
        packer = ImageDefinitions("Packer bake")
        gallery = SharedImageGalleries("Approved Compute Gallery")
        packer >> gallery >> mgmt

    with Cluster("Platform services"):
        law = LogAnalyticsWorkspaces("Log Analytics\n(central)")
        defender = SecurityCenter("Defender for Cloud\n(CIS + HIPAA assessments)")
        alerts = Alerts("Alerts -> ops action group\npolicy deny, KV 403,\nfirewall deny spike")
        kv = KeyVaults("Key Vault + CMK\n(rotation, purge protection)")

    with Cluster("Layered roots (own state, destroyed before the base)"):
        flow = LogAnalyticsWorkspaces("VNet flow logs\n(hub + prod, CMK storage,\nTraffic Analytics)")
        obs = Alerts("observability/\n13 change alerts +\nDefender export")
        sec = KeyVaults("secrets/\nscanner UAMI (KV Reader),\nnear-expiry alert")

    with Cluster("Spoke landing zones (peered to hub, default-deny NSG)"):
        sp_dev = VirtualNetworks("dev 10.1.0.0/16")
        sp_test = VirtualNetworks("test 10.2.0.0/16")
        sp_prod = VirtualNetworks("prod 10.3.0.0/16")
        sp_sand = VirtualNetworks("sandbox 10.4.0.0/16")

    tf >> mg_root
    tf >> hub

    # Egress inspection: every spoke's default route goes through the firewall,
    # which SNATs outbound to the internet. The firewall public IP is the only
    # egress point; the bastion public IP is the only inbound admin path.
    fw >> udr
    for sp in [sp_dev, sp_test, sp_prod, sp_sand]:
        hub >> Edge(label="peered") >> sp
        udr >> Edge(label="inspected egress", style="dashed") >> sp
    fw >> Edge(label="egress (SNAT)") >> inet
    inet >> Edge(label="admin (HTTPS portal)", style="dashed") >> bastion

    # Private path to the Key Vault.
    s_pl >> pe >> Edge(style="dashed") >> kv
    pe >> dns

    # Telemetry + CMK wiring.
    hub >> Edge(style="dotted") >> law
    fw >> Edge(style="dotted") >> law
    law >> Edge(style="dotted") >> alerts
    policy >> Edge(style="dotted") >> mg_workloads
    kv >> Edge(label="audit logs", style="dotted") >> law
    defender >> Edge(style="dotted") >> mg_root
    hub >> Edge(label="flow logs", style="dotted") >> flow >> law
    obs >> Edge(style="dotted") >> law
    sec >> Edge(label="reader", style="dotted") >> kv
