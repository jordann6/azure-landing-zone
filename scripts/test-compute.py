#!/usr/bin/env python3
"""Read-only guest hardening proof through Azure Run Command."""
import json
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
SOURCE = Path(os.environ.get("HARDENING_REPO", str(ROOT.parent / "azure-vm-hardening")))


def read(args):
    return json.loads(subprocess.check_output(args, text=True))


def main():
    target = read(["terraform", f"-chdir={ROOT / 'compute'}", "output", "-json", "management_vm"])
    vm = read(["az", "vm", "show", "-g", target["resource_group"], "-n", target["name"], "-o", "json"])
    assert vm["storageProfile"]["imageReference"]["id"].lower() == target["image_id"].lower(), "Unexpected boot image"
    assert vm["securityProfile"]["encryptionAtHost"] is True, "Host encryption missing"
    assert vm["securityProfile"]["uefiSettings"]["secureBootEnabled"] is True, "Secure Boot missing"
    assert vm["securityProfile"]["uefiSettings"]["vTpmEnabled"] is True, "vTPM missing"
    assert vm["osProfile"]["linuxConfiguration"]["disablePasswordAuthentication"] is True
    settings = vm["osProfile"]["linuxConfiguration"]["patchSettings"]
    assert settings["patchMode"] == "AutomaticByPlatform"
    assert settings["assessmentMode"] == "AutomaticByPlatform"
    assert settings["automaticByPlatformSettings"]["bypassPlatformSafetyChecksOnUserSchedule"] is True
    for interface in vm["networkProfile"]["networkInterfaces"]:
        nic = read(["az", "network", "nic", "show", "--ids", interface["id"], "-o", "json"])
        assert all(not ip.get("publicIPAddress") for ip in nic["ipConfigurations"]), "Public IP attached"
    print("PASS: golden image, no public IP, host encryption, trusted boot and patch settings")
    script = subprocess.check_output(["git", "-C", str(SOURCE), "show", "v2.0.1:scripts/check-hardening.sh"], text=True)
    with tempfile.TemporaryDirectory(prefix="alz-live-proof-") as directory:
        path = Path(directory) / "check.sh"
        path.write_text(script)
        response = read(["az", "vm", "run-command", "invoke", "-g", target["resource_group"],
                         "-n", target["name"], "--command-id", "RunShellScript", "--scripts", f"@{path}", "-o", "json"])
    messages = '\n'.join(entry.get("message", "") for entry in response.get("value", []))
    print(messages)
    if "HARDENING_OK" not in messages.splitlines() or "FAIL:" in messages or "HARDENING_FAILED" in messages:
        raise RuntimeError("Guest hardening proof failed or returned incomplete output")
    print("PASS: live VM hardening verified")


if __name__ == "__main__":
    main()
