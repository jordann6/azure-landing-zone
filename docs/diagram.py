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
from diagrams.azure.security import KeyVaults, SecurityCenter
from diagrams.azure.analytics import LogAnalyticsWorkspaces
from diagrams.azure.identity import ActiveDirectory
from diagrams.onprem.network import Internet
from diagrams.onprem.iac import Terraform
from diagrams.custom import Custom

# The mingrammer library has no Azure Bastion node, so use the official Azure
# Bastion service icon (docs/icons/azure-bastion.png) as a custom node.
BASTION_ICON = "docs/icons/azure-bastion.png"

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

    with Cluster("Management Group Hierarchy  ·  CIS initiative + Deny policies (inherited)"):
        mg_root = Managementgroups("jordann6\n(root)")
        mg_platform = Managementgroups("Platform")
        mg_workloads = Managementgroups("Workloads")
        mg_sandbox = Managementgroups("Sandbox")
        with Cluster("Workloads"):
            mg_dev = Managementgroups("Dev")
            mg_test = Managementgroups("Test")
            mg_prod = Managementgroups("Prod\n(stricter)")
        sub = Subscriptions("Subscription\n(single-sub demo)")

        mg_root >> [mg_platform, mg_workloads, mg_sandbox]
        mg_workloads >> [mg_dev, mg_test, mg_prod]

    with Cluster("Identity (Entra ID)"):
        aad = ActiveDirectory("7 persona groups\nRBAC @ MG scope + PIM JIT")

    with Cluster("Hub VNet  10.0.0.0/16  ·  centralus"):
        hub = VirtualNetworks("vnet-alz-hub")
        fw = Firewall("Azure Firewall\n(Standard, threat-intel Deny)")
        udr = RouteTables("UDR 0.0.0.0/0\n-> firewall")
        bastion = Custom("Bastion\n(only admin path)", BASTION_ICON)
        s_pl = Subnets("snet-privatelink")

        with Cluster("Private access"):
            pe = PrivateEndpoint("KV private endpoint")
            dns = DNSPrivateZones("privatelink DNS zones")

    with Cluster("Platform services"):
        law = LogAnalyticsWorkspaces("Log Analytics\n(central)")
        defender = SecurityCenter("Defender for Cloud\n(CIS assessment)")
        kv = KeyVaults("Key Vault + CMK\n(rotation, purge protection)")

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
    hub >> Edge(label="diagnostics", style="dotted") >> law
    kv >> Edge(label="audit logs", style="dotted") >> law
    defender >> Edge(style="dotted") >> mg_root
