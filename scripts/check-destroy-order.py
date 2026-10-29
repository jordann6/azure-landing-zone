#!/usr/bin/env python3
"""Fail if the workload teardown could cut the cluster's network before the cluster.

Terraform destroys in reverse dependency order. A resource the cluster (or
anything built on it) does not depend on, directly or transitively, may be
destroyed first. On 2026-10-29 the hub peerings and the Key Vault private
endpoint went before the cluster, the nodes lost egress and went NotReady, and
the Flux configuration and backup instance deletes hung for 30 minutes.

This reads `terraform graph` for workload/ (no credentials, no state) and checks
that every cluster-side resource transitively depends on every network-side one.
"""
import collections
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent / "workload"

# Torn down first. Each must still have its network when it is deleted.
CLUSTER_SIDE = [
    "azurerm_kubernetes_cluster.prod",
    "azurerm_kubernetes_cluster_extension.flux",
    "azurerm_kubernetes_flux_configuration.sre",
    "azurerm_kubernetes_cluster_extension.aks_backup",
    "azurerm_data_protection_backup_instance_kubernetes_cluster.aks_demo",
]

# Must outlive everything above: egress to the hub firewall, the private paths
# to the etcd CMK and the registry, and the firewall rules the cluster uses.
NETWORK_SIDE = [
    "azurerm_virtual_network_peering.prod_to_hub",
    "azurerm_virtual_network_peering.hub_to_prod",
    "azurerm_route_table.egress",
    "azurerm_subnet_route_table_association.aks",
    "azurerm_private_endpoint.kv",
    "azurerm_private_endpoint.acr",
    "azurerm_private_dns_zone_virtual_network_link.pe",
    "azurerm_firewall_policy_rule_collection_group.aks_egress",
    "azurerm_firewall_policy_rule_collection_group.aks_addons",
    "azurerm_firewall_policy_rule_collection_group.sre",
]

# The operator's cluster-admin role is scoped to the cluster, so it can only
# outlive what is deleted before the cluster: keep kubectl access through them.
ADMIN = "azurerm_role_assignment.aks_admin"
ADMIN_SIDE = [
    "azurerm_kubernetes_flux_configuration.sre",
    "azurerm_data_protection_backup_instance_kubernetes_cluster.aks_demo",
]


def graph():
    subprocess.run(["terraform", f"-chdir={ROOT}", "init", "-backend=false", "-input=false"],
                   check=True, capture_output=True)
    out = subprocess.run(["terraform", f"-chdir={ROOT}", "graph"],
                         check=True, capture_output=True, text=True).stdout
    edges = collections.defaultdict(set)
    for node, dep in re.findall(r'"([^"]+)" -> "([^"]+)"', out):
        edges[node].add(dep)
    return edges


def reachable(edges, start):
    seen, stack = set(), [start]
    while stack:
        for dep in edges[stack.pop()]:
            if dep not in seen:
                seen.add(dep)
                stack.append(dep)
    return seen


def main():
    edges = graph()
    missing = []
    for node in CLUSTER_SIDE:
        if node not in edges:
            missing.append(f"{node} is not in the graph (renamed?)")
            continue
        deps = reachable(edges, node)
        missing += [f"{node} does not depend on {n}" for n in NETWORK_SIDE if n not in deps]
    missing += [f"{n} does not depend on {ADMIN}" for n in ADMIN_SIDE
                if ADMIN not in reachable(edges, n)]
    for line in missing:
        print(f"FAIL {line}")
    checks = len(CLUSTER_SIDE) * len(NETWORK_SIDE) + len(ADMIN_SIDE)
    print(f"destroy order: {checks - len(missing)} passed, {len(missing)} failed")
    return 1 if missing else 0


if __name__ == "__main__":
    sys.exit(main())
