from diagrams import Diagram, Cluster, Edge
from diagrams.azure.compute import KubernetesServices, ContainerRegistries
from diagrams.azure.database import DatabaseForPostgresqlServers
from diagrams.azure.network import (
    Firewall,
    VirtualNetworks,
    RouteTables,
    PrivateEndpoint,
    DNSPrivateZones,
)
from diagrams.azure.security import KeyVaults
from diagrams.azure.identity import ManagedIdentities
from diagrams.azure.analytics import LogAnalyticsWorkspaces
from diagrams.onprem.network import Internet
from diagrams.onprem.iac import Terraform

graph_attrs = {"fontsize": "13", "bgcolor": "white", "pad": "0.5", "splines": "ortho"}
node_attrs = {"fontsize": "11"}

with Diagram(
    "Azure Landing Zone - Prod Workload Paved Road",
    filename="docs/workload-architecture",
    outformat="png",
    show=False,
    direction="TB",
    graph_attr=graph_attrs,
    node_attr=node_attrs,
):
    tf = Terraform("Terraform\n(workload/ root)")
    inet = Internet("Internet")

    with Cluster("Base landing zone (remote state)"):
        fw = Firewall("Hub Azure Firewall\n(egress inspection)")
        law = LogAnalyticsWorkspaces("Log Analytics\n(central)")

    with Cluster("Prod workload VNet  10.3.0.0/16  ·  centralus  (peered to hub, no public IP / NAT)"):
        udr = RouteTables("UDR 0.0.0.0/0\n-> hub firewall")

        with Cluster("snet-aks"):
            aks = KubernetesServices("Private AKS\n(no public API, UDR egress,\nworkload identity)")

        with Cluster("snet-apiserver (delegated)"):
            apisrv = KubernetesServices("API server\n(VNet integration,\nreaches KV over PE)")

        with Cluster("snet-data"):
            pg = DatabaseForPostgresqlServers("PostgreSQL Flexible\n(zone-redundant HA, CMK)")

        eso = ManagedIdentities("Workload identity\n(External Secrets)")
        kv = KeyVaults("Workload Key Vault\nCMK: etcd / disk / data")
        acr = ContainerRegistries("ACR Premium\n(CMK, no public access)")

        with Cluster("snet-privatelink"):
            pe_acr = PrivateEndpoint("ACR private endpoint")
            pe_kv = PrivateEndpoint("Key Vault private endpoint")
            dns = DNSPrivateZones("privatelink DNS zones")

    tf >> aks

    # Egress: all cluster traffic leaves only through the hub firewall.
    aks >> Edge(label="egress (UDR)") >> udr >> Edge(label="inspected") >> fw >> Edge(label="SNAT") >> inet

    # Private pulls and secrets, no internet path.
    aks >> Edge(label="pull images", style="dashed") >> pe_acr >> Edge(style="dashed") >> acr
    eso >> Edge(label="read DB secret", style="dashed") >> pe_kv >> Edge(style="dashed") >> kv
    pe_acr >> dns

    # CMK envelope encryption. The API server reaches the etcd CMK over the Key Vault
    # private endpoint (KV stays default-Deny); node/OS disks use the disk CMK direct.
    apisrv >> Edge(label="etcd KMS over PE", style="dotted") >> pe_kv
    kv >> Edge(label="disk CMK (DES)", style="dotted") >> aks
    aks >> Edge(label="app traffic") >> pg
    kv >> Edge(label="CMK", style="dotted") >> pg

    # Control-plane audit logging.
    aks >> Edge(label="audit logs", style="dotted") >> law
