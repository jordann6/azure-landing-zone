#!/usr/bin/env python3
"""Deploy only the management root from a reviewed, saved creation plan."""
import json
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
TF = ["terraform", f"-chdir={ROOT / 'compute'}"]


def main():
    os.umask(0o077)
    subprocess.run(TF + ["init", "-input=false"], check=True)
    with tempfile.TemporaryDirectory(prefix="alz-management-") as directory:
        key = Path(directory) / "key"
        subprocess.run(["ssh-keygen", "-q", "-t", "rsa", "-b", "3072", "-N", "", "-f", str(key)], check=True)
        inputs = Path(directory) / "compute.tfvars.json"
        inputs.write_text(json.dumps({"enable_management_vm": True, "ssh_public_key": key.with_suffix('.pub').read_text().strip()}))
        inputs.chmod(0o600)
        subprocess.run(TF + ["plan", "-input=false", "-out=tfplan", f"-var-file={inputs}"], check=True)
        plan = json.loads(subprocess.check_output(TF + ["show", "-json", "tfplan"], text=True))
        for resource in plan.get("resource_changes", []):
            actions = resource["change"]["actions"]
            if actions not in (["no-op"], ["read"], ["create"]):
                raise RuntimeError(f"Review non-additive change before deploying: {resource['address']} {actions}")
        subprocess.run(TF + ["apply", "-input=false", "tfplan"], check=True)
        # Opt-in for sessions that SSH through Bastion (docs/runbooks/grafana-access.md).
        # Default stays as before: the private key dies with the temp directory.
        keep = os.environ.get("KEEP_SSH_KEY")
        if keep:
            target = Path(keep).expanduser()
            target.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
            target.write_bytes(key.read_bytes())
            target.chmod(0o600)
            print(f"Kept the session SSH key at {target}; delete it at teardown.")


if __name__ == "__main__":
    main()
