#!/usr/bin/env python3
"""Supervised image build with fixed-expiry exemptions and unconditional cleanup."""
import datetime
import json
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
SOURCE = Path(os.environ.get("HARDENING_REPO", str(ROOT.parent / "azure-vm-hardening"))).resolve()
FLAGS = ["-var=enable_firewall=false", "-var=enable_bastion=false",
         "-var=enable_private_endpoints=false", "-var=enable_fortigate=false"]


def run(args, **kwargs):
    return subprocess.run([str(a) for a in args], check=True, **kwargs)


def capture(args):
    return subprocess.check_output([str(a) for a in args], text=True)


def console_ip_rules(output):
    # Backend lock notices share stdout with the console's encoded JSON value.
    values = [line for line in output.splitlines() if line.strip() and not line.startswith(
        ("Acquiring state lock.", "Releasing state lock."))]
    if len(values) != 1:
        raise RuntimeError("Terraform console did not return exactly one input value")
    rules = json.loads(json.loads(values[0]))
    if not isinstance(rules, list) or not all(isinstance(rule, str) for rule in rules):
        raise RuntimeError("Workstation input must be a list of CIDR strings")
    return rules


def configure_build(enabled, expiry):
    tf = ["terraform", f"-chdir={ROOT / 'terraform'}"]
    run(tf + ["plan", "-input=false", "-out=tfplan", *FLAGS,
              f"-var=enable_image_build={str(enabled).lower()}",
              f"-var=image_build_exemption_expires_on={expiry}"])
    plan = json.loads(capture(tf + ["show", "-json", "tfplan"]))
    allowed = {"azurerm_resource_group", "azurerm_resource_group_policy_exemption",
               "azurerm_shared_image_gallery", "azurerm_shared_image",
               "azurerm_policy_definition", "azurerm_management_group_policy_assignment",
               "azurerm_role_assignment"}
    for change in plan["resource_changes"]:
        actions = change["change"]["actions"]
        if actions in (["no-op"], ["read"]):
            continue
        if change["type"] not in allowed:
            raise RuntimeError(f"Unexpected image setup change: {change['address']} {actions}")
        if "delete" in actions and not (change["type"] == "azurerm_resource_group_policy_exemption"
                                       or change["address"] == "azurerm_resource_group.image_build[0]"):
            raise RuntimeError(f"Unexpected deletion: {change['address']}")
    run(tf + ["apply", "-input=false", "tfplan"])


def main():
    os.umask(0o077)
    release = "v2.0.1"
    run(["git", "-C", SOURCE, "rev-parse", "--verify", f"refs/tags/{release}"], stdout=subprocess.DEVNULL)
    feature = capture(["az", "feature", "show", "--namespace", "Microsoft.Compute", "--name",
                       "EncryptionAtHost", "--query", "properties.state", "-o", "tsv"]).strip()
    if feature != "Registered":
        raise RuntimeError("EncryptionAtHost is not Registered; run make compute-prereqs and wait")
    gallery = json.loads(capture(["terraform", f"-chdir={ROOT / 'terraform'}", "output", "-json", "compute_gallery"]))
    expiry = (datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(hours=2)).strftime("%Y-%m-%dT%H:%M:%SZ")
    # Keep source inputs private; Terraform console returns JSON for this expression.
    ip_rules = console_ip_rules(subprocess.check_output(
        ["terraform", f"-chdir={ROOT / 'terraform'}", "console", *FLAGS],
        input="jsonencode(var.deployer_ip_cidrs)\n", text=True))
    if len(ip_rules) != 1 or not ip_rules[0].endswith("/32"):
        raise RuntimeError("Set exactly one workstation /32 in deployer_ip_cidrs before baking")
    with tempfile.TemporaryDirectory(prefix="alz-image-") as directory:
        directory = Path(directory)
        # Local tag is used until an explicit push publishes the same release.
        requirements = directory / "requirements.yml"
        requirements.write_text(json.dumps({"roles": [{"name": "cis_baseline", "src": SOURCE.as_uri(),
                                                       "scm": "git", "version": release}]}))
        run(["ansible-galaxy", "role", "install", "-r", requirements, "--roles-path", directory / "roles"])
        version = os.environ.get("IMAGE_VERSION", "1.0." + str(int(datetime.datetime.now(datetime.timezone.utc).timestamp())))
        # Gallery version components are signed 32-bit integers.
        if any(not n.isdigit() or int(n) > 2147483647 for n in version.split('.')) or len(version.split('.')) != 3:
            raise RuntimeError("IMAGE_VERSION must contain three integer components <= 2147483647")
        variables = {"subscription_id": gallery["subscription_id"], "location": gallery["location"],
                     "gallery_name": gallery["name"], "gallery_image_name": gallery["image_name"],
                     "image_resource_group": gallery["resource_group_name"], "image_version": version,
                     "build_resource_group": f"rg-{gallery['project']}-image-build", "keep_managed_image": False,
                     "ssh_allowed_ip": ip_rules[0], "role_path": str(directory / "roles"),
                     "vm_size": os.environ.get("COMPUTE_VM_SIZE", "Standard_B2s")}
        inputs = directory / "build.pkrvars.json"
        inputs.write_text(json.dumps(variables))
        inputs.chmod(0o600)
        cwd = SOURCE / "packer"
        run(["packer", "init", "hardened-ubuntu.pkr.hcl"], cwd=cwd)
        run(["packer", "validate", f"-var-file={inputs}", "hardened-ubuntu.pkr.hcl"], cwd=cwd)
        try:
            configure_build(True, expiry)
            run(["packer", "build", "-on-error=cleanup", f"-var-file={inputs}", "hardened-ubuntu.pkr.hcl"],
                cwd=cwd, timeout=2400)
        finally:
            configure_build(False, expiry)


if __name__ == "__main__":
    main()
