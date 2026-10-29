#!/usr/bin/env python3
"""Inventory this landing zone and fail on survivors or an incomplete query."""
import json
import os
import subprocess
import sys


def query(*args):
    result = subprocess.run(["az", *args, "-o", "json"], text=True, capture_output=True)
    if result.returncode:
        raise RuntimeError(f"Azure query failed ({' '.join(args)}): {result.stderr.strip()}")
    data = json.loads(result.stdout)
    if not isinstance(data, list):
        raise RuntimeError("Azure inventory did not return a list")
    return data


def main():
    project = os.environ.get("PROJECT", "alz").lower()
    prefix = f"rg-{project}-"
    resources = query("resource", "list")
    groups = query("group", "list")
    exemptions = query("policy", "exemption", "list", "--disable-scope-strict-match", "true")
    billable = {
        "microsoft.network/azurefirewalls", "microsoft.network/bastionhosts",
        "microsoft.network/publicipaddresses", "microsoft.network/privateendpoints",
        "microsoft.network/networkinterfaces", "microsoft.network/natgateways",
        "microsoft.network/loadbalancers", "microsoft.network/virtualnetworkgateways",
        "microsoft.compute/virtualmachines", "microsoft.compute/virtualmachinescalesets",
        "microsoft.compute/disks", "microsoft.compute/snapshots", "microsoft.compute/images",
        "microsoft.containerservice/managedclusters", "microsoft.dbforpostgresql/flexibleservers",
        "microsoft.app/containerapps", "microsoft.containerregistry/registries",
        "microsoft.sql/servers/databases", "microsoft.apimanagement/service",
        "microsoft.network/networkwatchers/flowlogs",
        # SRE demo layer (workload/, enable_sre_demo and enable_aks_backup).
        # Ingestion, queries and snapshots bill by usage; none may outlive a session.
        "microsoft.monitor/accounts", "microsoft.insights/datacollectionendpoints",
        "microsoft.insights/datacollectionrules", "microsoft.alertsmanagement/prometheusrulegroups",
    }
    survivors = []
    print("== Landing-zone teardown inventory ==")
    # The top-level resource inventory can omit nested gallery versions.
    # Enumerate each owned gallery directly so billed storage cannot be missed.
    for gallery in [r for r in resources if r["type"].lower() == "microsoft.compute/galleries"
                    and r.get("resourceGroup", "").lower().startswith(prefix)]:
        group = gallery["resourceGroup"]
        for definition in query("sig", "image-definition", "list", "-g", group,
                                "--gallery-name", gallery["name"]):
            for version in query("sig", "image-version", "list", "-g", group,
                                 "--gallery-name", gallery["name"],
                                 "--gallery-image-definition", definition["name"]):
                survivors.append(f"billed gallery version: {gallery['name']}/{definition['name']}/{version['name']}")
    for item in resources:
        rg = item.get("resourceGroup", "").lower()
        if rg == f"rg-{project}-tfstate":
            # bootstrap/ is the one standing layer: it holds every root's state.
            if item["type"].lower() == "microsoft.storage/storageaccounts":
                print(f"  STANDING state backend: {item['name']} (bootstrap/, never destroyed)")
            continue
        tags = item.get("tags") or {}
        if not (rg.startswith(prefix) or tags.get("project") == "azure-landing-zone"):
            continue
        kind = item["type"].lower()
        if kind in billable:
            survivors.append(f"{item['type']}: {item['name']}")
        elif kind == "microsoft.storage/storageaccounts" and "flow" in item["name"].lower():
            # Flow-log storage bills by volume and is gated by enable_flow_logs.
            survivors.append(f"flow-log storage account: {item['name']}")
        elif kind == "microsoft.managedidentity/userassignedidentities" and "secrets-scanner" in item["name"].lower():
            # secrets/ root: a destroyed root leaves no scanner identity behind.
            survivors.append(f"secrets scanner identity: {item['name']}")
        elif kind == "microsoft.insights/scheduledqueryrules" and "secret-near-expiry" in item["name"].lower():
            survivors.append(f"secrets near-expiry alert: {item['name']}")
        elif kind == "microsoft.compute/galleries/images/versions":
            survivors.append(f"billed gallery version: {item['name']}")
        elif kind == "microsoft.dataprotection/backupvaults" and "aks-demo" in item["name"].lower():
            # The restore drill's vault has soft delete Off and holds nothing worth
            # keeping, so it is never a retained item.
            survivors.append(f"AKS Backup demo vault: {item['name']}")
        elif kind == "microsoft.storage/storageaccounts" and "aksbkp" in item["name"].lower():
            survivors.append(f"AKS Backup extension storage: {item['name']}")
        elif kind == "microsoft.managedidentity/userassignedidentities" and any(
                n in item["name"].lower() for n in ("-grafana", "-slo-data", "-aks-backup-storage")):
            survivors.append(f"SRE demo identity: {item['name']}")
        elif kind == "microsoft.dataprotection/backupvaults":
            print(f"  RETAINED backup vault: {item['name']} (check recovery points and retention)")
        elif kind == "microsoft.keyvault/vaults":
            print(f"  RETAINED live Key Vault: {item['name']}")
    for group in groups:
        if group["name"].lower() == f"rg-{project}-image-build":
            survivors.append(f"image-build resource group: {group['name']}")
        if group["name"].lower() == f"rg-{project}-secrets":
            survivors.append(f"secrets resource group: {group['name']}")
        if group["name"].lower() == f"rg-{project}-prod-aks-snapshots":
            # Operational-tier snapshots live here and are not soft-delete protected,
            # so a surviving group can still be holding billed snapshots.
            survivors.append(f"AKS Backup snapshot resource group: {group['name']}")
    for exemption in exemptions:
        if f"/resourcegroups/{prefix}" in exemption["id"].lower():
            # No build exemption may remain after teardown, even before expiry.
            survivors.append(f"policy exemption: {exemption['name']}")
    for item in survivors:
        print(f"  ALIVE: {item}")
    if survivors:
        print(f"== FAIL: {len(survivors)} resource(s) require cleanup. ==")
        return 1
    print("== PASS: no checked compute/network/workload resources or build exemptions remain. ==")
    print("Retained items above and soft-deleted vaults are not a zero-invoice guarantee.")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (RuntimeError, ValueError, KeyError, OSError) as exc:
        print(f"== FAIL: teardown verification incomplete: {exc} ==", file=sys.stderr)
        sys.exit(1)
