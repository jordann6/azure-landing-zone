"""Member portal architecture (docs/portal-architecture.png).

Official Azure service icons from the mingrammer `diagrams` library. Run from
the repo root: python3 docs/portal.py
"""

from diagrams import Cluster, Diagram, Edge
from diagrams.azure.compute import ContainerApps, ContainerRegistries
from diagrams.azure.database import SQLServers
from diagrams.azure.identity import ExternalIdentities, ManagedIdentities
from diagrams.azure.integration import APIManagement, LogicApps
from diagrams.azure.managementgovernance import Alerts, Policy
from diagrams.azure.monitor import ApplicationInsights, AzureWorkbooks, LogAnalyticsWorkspaces
from diagrams.azure.network import FrontDoors, PrivateEndpoint
from diagrams.azure.networking import WebApplicationFirewallPolicieswaf
from diagrams.onprem.client import Users

graph_attrs = {"fontsize": "13", "bgcolor": "white", "pad": "0.5", "splines": "spline", "nodesep": "0.6", "ranksep": "0.9"}
node_attrs = {"fontsize": "11"}

with Diagram(
    "Member Portal on the Landing Zone",
    filename="docs/portal-architecture",
    outformat="png",
    show=False,
    direction="LR",
    graph_attr=graph_attrs,
    node_attr=node_attrs,
):
    members = Users("Members\n(pharmacy staff)")
    partners = Users("Partners\n(wholesalers)")

    with Cluster("Entra External ID tenant  ·  US data residency"):
        extid = ExternalIdentities("Sign-up / sign-in\nuser flow")

    with Cluster("Edge (global)  ·  rg-alz-portal-edge"):
        apim = APIManagement("API Management\n(Consumption)\nkey + rate limit")
        waf = WebApplicationFirewallPolicieswaf("WAF\nDRS 2.1 + Bot Manager\n+ per-IP rate limit")
        afd = FrontDoors("Front Door Premium\nprobes /health")
        logic = LogicApps("Logic App\ndaily report")

    with Cluster("App tier  ·  internal Container Apps, no public IP"):
        with Cluster("westus2  ·  priority 1"):
            pe_w = PrivateEndpoint("Private Link")
            app_w = ContainerApps("Portal app")
        with Cluster("eastus2  ·  priority 2"):
            pe_e = PrivateEndpoint("Private Link")
            app_e = ContainerApps("Portal app")
        mi = ManagedIdentities("App managed identity\n(token, no password)")
        acr = ContainerRegistries("Container Registry")

    with Cluster("Data tier  ·  rg-alz-portal-data (phi)  ·  measured planned failover: RTO ~7 s, RPO 0"):
        sql_p = SQLServers("SQL primary\ncentralus")
        sql_s = SQLServers("SQL geo-secondary\nwestus2")

    with Cluster("Landing zone (inherited)"):
        policy = Policy("Deny policies\nregions, tags,\nphi: no public access")
        law = LogAnalyticsWorkspaces("Central Log Analytics")
        appi = ApplicationInsights("App Insights\n5-location test\n99.9% SLO")
        alerts = Alerts("Alerts -> ops\naction group")
        wb = AzureWorkbooks("Ops workbook")

    # Member path (fast failover clock: Front Door between app regions).
    members >> Edge(label="HTTPS") >> waf >> afd
    members >> Edge(label="sign in", style="dashed") >> extid
    afd >> Edge(label="priority 1") >> pe_w >> app_w
    afd >> Edge(label="priority 2", style="dashed") >> pe_e >> app_e

    # Partner and integration paths.
    partners >> Edge(label="subscription key") >> apim >> afd
    logic >> Edge(label="06:00 CT") >> afd

    # Data path (slow failover clock: the failover group between data regions).
    app_w >> Edge(label="failover group listener") >> sql_p
    app_e >> Edge(label="failover group listener") >> sql_p
    sql_p >> Edge(label="geo-replication", style="dashed") >> sql_s

    # Identity and images.
    mi >> Edge(style="dotted") >> [app_w, app_e]
    acr >> Edge(label="AcrPull", style="dotted") >> app_w

    # Governance and telemetry.
    policy >> Edge(style="dotted") >> sql_p
    [afd, app_w, sql_p] >> Edge(label="logs", style="dotted") >> law
    appi >> Edge(style="dotted") >> law
    law >> Edge(style="dotted") >> alerts
    law >> Edge(style="dotted") >> wb
