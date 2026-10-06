#!/usr/bin/env python3
"""Prove each compute denial independently against a compliant gallery template."""
import copy
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile


def az(*args):
    return subprocess.run(["az", *args], capture_output=True, text=True)


def checked(*args):
    result = az(*args, "-o", "json")
    if result.returncode:
        raise RuntimeError(result.stderr.strip())
    return json.loads(result.stdout)


def is_denial(result, assignment):
    output = (result.stdout + result.stderr).lower()
    return (result.returncode != 0 and "requestdisallowedbypolicy" in output
            and f"/policyassignments/{assignment}" in output)


def main():
    project = os.environ.get("PROJECT", "alz")
    location = os.environ.get("LOCATION", "centralus")
    gallery = os.environ.get("COMPUTE_GALLERY", f"gal{project}")
    image = "hardened-ubuntu-2204"
    versions = checked("sig", "image-version", "list", "-g", f"rg-{project}-images",
                       "--gallery-name", gallery, "--gallery-image-definition", image)
    if not versions:
        raise RuntimeError("No golden image version exists; run make build-image first")
    image_id = max(versions, key=lambda v: tuple(map(int, v["name"].split("."))))["id"]
    subnet = checked("network", "vnet", "subnet", "show", "-g", f"rg-{project}-hub",
                     "--vnet-name", f"vnet-{project}-hub", "-n", "snet-management")["id"]
    rg = f"rg-{project}-compute-proof"
    # Refuse to adopt or delete a preexisting resource group.
    if checked("group", "exists", "-n", rg):
        raise RuntimeError(f"Proof resource group already exists: {rg}; inspect it before retrying")
    failed = 0
    try:
        checked("group", "create", "-n", rg, "-l", location, "--tags", "owner=guardrail-test",
                "cost_center=platform", "environment=test", "data_classification=internal")
        with tempfile.TemporaryDirectory(prefix="alz-policy-") as directory:
            key = Path(directory) / "key"
            subprocess.run(["ssh-keygen", "-q", "-t", "rsa", "-b", "2048", "-N", "", "-f", str(key)], check=True)
            vm = {
                "type": "Microsoft.Compute/virtualMachines", "apiVersion": "2024-03-01",
                "name": "vm-compute-proof", "location": location,
                "dependsOn": ["[resourceId('Microsoft.Network/networkInterfaces', 'nic-compute-proof')]"],
                "properties": {
                    "hardwareProfile": {"vmSize": os.environ.get("COMPUTE_VM_SIZE", "Standard_B2s")},
                    "securityProfile": {"encryptionAtHost": True},
                    "storageProfile": {"imageReference": {"id": image_id}, "osDisk": {
                        "createOption": "FromImage", "deleteOption": "Delete",
                        "managedDisk": {"storageAccountType": "Standard_LRS"}}},
                    "osProfile": {"computerName": "compute-proof", "adminUsername": "proofadmin",
                                  "linuxConfiguration": {"disablePasswordAuthentication": True,
                                      "ssh": {"publicKeys": [{"path": "/home/proofadmin/.ssh/authorized_keys",
                                          "keyData": key.with_suffix(".pub").read_text().strip()}]}}},
                    "networkProfile": {"networkInterfaces": [{"id": "[resourceId('Microsoft.Network/networkInterfaces', 'nic-compute-proof')]"}]},
                },
            }
            nic = {"type": "Microsoft.Network/networkInterfaces", "apiVersion": "2023-09-01",
                   "name": "nic-compute-proof", "location": location,
                   "properties": {"ipConfigurations": [{"name": "private", "properties": {
                       "privateIPAllocationMethod": "Dynamic", "subnet": {"id": subnet}}}]}}
            template = {"$schema": "https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#",
                        "contentVersion": "1.0.0.0", "resources": [nic, vm]}
            path = Path(directory) / "template.json"
            path.write_text(json.dumps(template))
            result = az("deployment", "group", "validate", "-g", rg, "-n", "compliant-control", "--template-file", str(path))
            if result.returncode:
                raise RuntimeError(f"Compliant template validation failed: {result.stderr}")
            print("  PASS: compliant gallery VM template validates")
            for assignment in ("approved-vm-images", "allowed-vm-sizes", "require-host-encryption"):
                candidate = copy.deepcopy(template)
                props = candidate["resources"][1]["properties"]
                if assignment == "approved-vm-images":
                    props["storageProfile"]["imageReference"] = {
                        "publisher": "Canonical", "offer": "0001-com-ubuntu-server-jammy",
                        "sku": "22_04-lts-gen2", "version": "latest"}
                elif assignment == "allowed-vm-sizes":
                    props["hardwareProfile"]["vmSize"] = "Standard_D2as_v5"
                else:
                    props["securityProfile"]["encryptionAtHost"] = False
                path.write_text(json.dumps(candidate))
                result = az("deployment", "group", "validate", "-g", rg, "-n", assignment, "--template-file", str(path))
                if result.returncode == 0:
                    # Some validation paths omit policy enforcement. Create is
                    # authorized only after a compliant control validated. The
                    # finally block removes the entire proof group immediately.
                    print(f"  Validate did not deny {assignment}; checking create")
                    result = az("deployment", "group", "create", "-g", rg, "-n", assignment, "--template-file", str(path))
                    if result.returncode == 0:
                        failed += 1
                        print(f"  FAIL: {assignment} allowed creation")
                        break
                if is_denial(result, assignment):
                    print(f"  PASS: {assignment} returned RequestDisallowedByPolicy")
                else:
                    failed += 1
                    print(f"  FAIL: no attributable denial for {assignment}: {result.stderr}")
    finally:
        result = az("group", "delete", "-n", rg, "--yes")
        if result.returncode:
            raise RuntimeError(f"Proof cleanup failed: {result.stderr}")
    return int(failed != 0)


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (RuntimeError, ValueError, KeyError, OSError, subprocess.SubprocessError) as exc:
        print(f"  FAIL: {exc}", file=sys.stderr)
        sys.exit(1)
