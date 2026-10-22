"""Render docs/architecture.png for the base landing zone.

Run from the repo root: python3 docs/diagram.py (needs diagrams and Graphviz).
Reads left to right: governance, then the hub, then the spokes it inspects, with
logging on the right. The prod spoke belongs to the workload/ root and is drawn
in docs/workload.py.
"""

import os

from diagrams import Cluster, Diagram, Edge
from diagrams.azure.analytics import LogAnalyticsWorkspaces
from diagrams.azure.compute import SharedImageGalleries
from diagrams.azure.general import Managementgroups, Subscriptions
from diagrams.azure.identity import ActiveDirectory
from diagrams.azure.managementgovernance import Alerts, Policy
from diagrams.azure.network import Firewall, PrivateEndpoint, RouteTables, VirtualNetworks
from diagrams.azure.security import KeyVaults, SecurityCenter
from diagrams.custom import Custom
from diagrams.onprem.network import Internet

# The mingrammer library has no Azure Bastion node, so use the official Azure
# Bastion service icon (docs/icons/azure-bastion.png) as a custom node.
BASTION_ICON = os.path.join(os.path.dirname(os.path.abspath(__file__)), "icons", "azure-bastion.png")

GOV = {"bgcolor": "#eef6ff", "color": "#7299bd", "fontsize": "15"}
HOURLY = {"bgcolor": "#fff4e7", "color": "#d49447", "fontsize": "15"}
SPOKES = {"bgcolor": "#f4f9ee", "color": "#8fb56a", "fontsize": "15"}
EGRESS = "#ac6413"

with Diagram(
    "Azure Landing Zone | base",
    filename="docs/architecture",
    outformat="png",
    show=False,
    direction="LR",
    graph_attr={"fontsize": "20", "pad": "0.4", "nodesep": "0.5", "ranksep": "1.0"},
    node_attr={"fontsize": "12"},
):
    with Cluster("Governance | free layer, inherited by every resource", graph_attr=GOV):
        root = Managementgroups("Root MG\nCIS + HIPAA scoring")
        workloads = Managementgroups("Workloads MG\n(Dev, Test, Prod beneath)")
        sub = Subscriptions("Single subscription")
        deny = Policy("Deny policies\npublic IP, regions, tags,\nphi, VM image + SKU")
        entra = ActiveDirectory("7 persona groups\nPIM to Prod (P2)")
        root >> workloads >> sub
        deny >> Edge(style="dashed") >> root
        entra >> Edge(style="dashed") >> root

    with Cluster("Hub VNet 10.0.0.0/16 | hourly, flag-gated", graph_attr=HOURLY):
        bastion = Custom("Bastion\nonly admin path", BASTION_ICON)
        udr = RouteTables("Route table\n0.0.0.0/0 -> firewall")
        fw = Firewall("Azure Firewall\nthreat-intel deny")
        pe = PrivateEndpoint("Key Vault\nprivate endpoint")

    with Cluster("Spokes | peered, default-deny NSG", graph_attr=SPOKES):
        dev = VirtualNetworks("dev 10.1")
        test = VirtualNetworks("test 10.2")
        sandbox = VirtualNetworks("sandbox 10.4")

    inet = Internet("Internet")

    with Cluster("Logging, keys, compute", graph_attr=GOV):
        law = LogAnalyticsWorkspaces("Central\nLog Analytics")
        alerts = Alerts("Alerts\npolicy deny, KV 403,\nfirewall deny spike")
        defender = SecurityCenter("Defender for Cloud\nfree CSPM")
        kv = KeyVaults("Key Vault\nCMK, purge protection")
        gallery = SharedImageGalleries("Compute Gallery\nonly allowed VM images")

    for spoke in (dev, test, sandbox):
        spoke >> Edge(color=EGRESS) >> udr
    udr >> Edge(color=EGRESS) >> fw >> Edge(color=EGRESS, label="SNAT") >> inet

    pe >> Edge(style="dashed") >> kv
    fw >> Edge(style="dotted", label="rule logs") >> law
    law >> alerts
    defender >> Edge(style="dotted") >> law
    gallery >> Edge(style="invis") >> defender
