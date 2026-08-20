from diagrams import Diagram, Cluster, Edge
from diagrams.azure.network import VirtualNetworks, Subnets, Firewall, RouteTables
from diagrams.azure.general import ManagementGroups, Subscriptions
from diagrams.onprem.network import Internet
from diagrams.onprem.iac import Terraform

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

    with Cluster("Management Group Hierarchy"):
        mg_root = ManagementGroups("jordann6\n(org root)")
        mg_platform = ManagementGroups("Platform MG")
        mg_workloads = ManagementGroups("Workloads MG\n+ 3 policy assignments")
        mg_sandbox = ManagementGroups("Sandbox MG")

        sub = Subscriptions("Azure subscription 1\n(vended into Workloads)")

        mg_root >> mg_platform
        mg_root >> mg_workloads
        mg_root >> mg_sandbox
        mg_workloads >> sub

    with Cluster("Hub VNet  10.0.0.0/16  ·  eastus"):
        hub = VirtualNetworks("vnet-alz-hub")
        s_fw = Subnets("AzureFirewallSubnet\n/26  (reserved)")
        s_gw = Subnets("GatewaySubnet\n/27  (reserved)")
        s_bas = Subnets("AzureBastionSubnet\n/26  (reserved)")
        s_mgmt = Subnets("snet-management\n/24  + NSG")

        with Cluster("FortiGate NVA (opt-in)"):
            inet = Internet("Internet")
            fgt = Firewall("FortiGate-VM\nuntrust / trust")
            udr = RouteTables("UDR: 0.0.0.0/0\n-> trust 10.0.5.4")
            inet >> Edge(label="untrust") >> fgt >> Edge(label="trust") >> udr

    with Cluster("Platform spoke  10.1.0.0/16"):
        spoke_plat = VirtualNetworks("vnet-alz-platform")
        s_plat = Subnets("snet-workloads /24")

    with Cluster("Sandbox spoke  10.2.0.0/16"):
        spoke_sand = VirtualNetworks("vnet-alz-sandbox")
        s_sand = Subnets("snet-workloads /24")

    tf >> mg_root
    tf >> hub

    hub >> Edge(label="peered") >> spoke_plat
    hub >> Edge(label="peered") >> spoke_sand

    # Spoke workload subnets force default egress through the FortiGate trust IP.
    udr >> Edge(label="inspected egress", style="dashed") >> s_plat
    udr >> Edge(label="inspected egress", style="dashed") >> s_sand
