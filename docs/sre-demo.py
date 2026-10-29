"""SRE demo layer on the prod paved road (enable_sre_demo, enable_aks_backup).

Run from the repo root: python3 docs/sre-demo.py -> docs/sre-demo-architecture.png
"""
from diagrams import Diagram, Cluster, Edge
from diagrams.azure.compute import KubernetesServices, ContainerRegistries
from diagrams.azure.managementgovernance import Alerts
from diagrams.azure.monitor import Metrics, Monitor
from diagrams.azure.network import Firewall, PrivateEndpoint
from diagrams.azure.other import BackupVault
from diagrams.azure.security import KeyVaults
from diagrams.azure.storage import BlobStorage, StorageAccounts
from diagrams.onprem.client import User
from diagrams.onprem.gitops import Flux
from diagrams.onprem.monitoring import Grafana
from diagrams.onprem.vcs import Github

graph_attrs = {"fontsize": "13", "bgcolor": "white", "pad": "0.5", "splines": "ortho", "nodesep": "0.7"}
node_attrs = {"fontsize": "11"}

with Diagram(
    "Azure Landing Zone - SRE demo on the prod paved road",
    filename="docs/sre-demo-architecture",
    outformat="png",
    show=False,
    direction="LR",
    graph_attr=graph_attrs,
    node_attr=node_attrs,
):
    gh = Github("GitHub\ngitops/ (digests, structure)")
    oncall = User("On-call\n(Sev 1 page, Sev 3 ticket)")

    with Cluster("Base landing zone (hub)"):
        fw = Firewall("Hub Azure Firewall\n(FQDN allowlist)")
        ag = Alerts("ag-alz-ops\naction group")

    with Cluster("Prod spoke  10.3.0.0/16  (private AKS, UDR egress)"):
        with Cluster("Private AKS (3 x D2s v3)"):
            flux = Flux("Flux extension\ninfra / apps / data")
            app = KubernetesServices("slo-demo api\n+ load generator")
            pg = KubernetesServices("slo-data\nPostgres + writer\n(CMK disk)")
            graf = Grafana("Grafana\n(workload identity)")
            bkx = KubernetesServices("Backup extension")

        kv = KeyVaults("Workload Key Vault\n(per-secret identities)")
        acr = ContainerRegistries("ACR Premium\n(pinned digests)")
        pe_blob = PrivateEndpoint("Blob private endpoint")

    with Cluster("Azure Monitor"):
        amw = Metrics("Azure Monitor workspace\n(managed Prometheus)")
        rules = Monitor("SLO recording rules\n+ burn-rate alerts")

    with Cluster("AKS Backup (operational tier)"):
        vault = BackupVault("bv-alz-aks-demo\n(soft delete Off)")
        snaps = StorageAccounts("Snapshot RG\n(incremental disk snapshots)")
        meta = BlobStorage("Extension storage\n(cluster metadata)")

    # GitOps: a commit, not kubectl, changes the cluster.
    gh >> Edge(label="pull over firewall") >> fw >> flux
    flux >> Edge(label="reconcile") >> app
    flux >> Edge(label="reconcile") >> pg
    flux >> Edge(label="reconcile") >> graf
    acr >> Edge(label="images by digest", style="dashed") >> app

    # Metrics and paging.
    app >> Edge(label="scraped (ama-metrics)") >> amw >> rules >> Edge(label="fires") >> ag
    ag >> Edge(label="email") >> oncall
    graf >> Edge(label="PromQL", style="dashed") >> amw
    kv >> Edge(label="CSI secrets", style="dotted") >> pg

    # Backup and restore of the stateful namespace.
    vault >> Edge(label="trusted access") >> bkx
    bkx >> Edge(label="metadata") >> pe_blob >> meta
    vault >> Edge(label="snapshot / restore", style="dashed") >> snaps
    snaps >> Edge(style="dashed") >> pg
