"""Regression checks for fail-closed teardown and attributable denial evidence."""
import importlib.util
from pathlib import Path
import subprocess
import unittest
from unittest.mock import patch


def load(name):
    path = Path(__file__).with_name(name + ".py")
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


verify = load("verify-teardown")
policy = load("test-compute-policies")
build = load("build-image")


class ProofTests(unittest.TestCase):
    def test_console_backend_lock_notices_do_not_hide_input(self):
        output = 'Acquiring state lock. This may take a few moments...\n"[\\"203.0.113.4/32\\"]"\nReleasing state lock. This may take a few moments...\n'
        self.assertEqual(build.console_ip_rules(output), ["203.0.113.4/32"])

    def test_console_ambiguous_input_is_rejected(self):
        with self.assertRaises(RuntimeError):
            build.console_ip_rules('"[]"\n"[]"\n')

    def test_api_failure_is_not_clean_inventory(self):
        with patch.object(verify, "query", side_effect=RuntimeError("API unavailable")):
            with self.assertRaises(RuntimeError):
                verify.main()

    def test_private_management_disk_is_a_survivor(self):
        disk = {"resourceGroup": "rg-alz-compute", "type": "Microsoft.Compute/disks", "name": "disk-alz-mgmt-os"}
        with patch.object(verify, "query", side_effect=[[disk], [], []]):
            self.assertEqual(verify.main(), 1)

    def test_expired_build_exemption_is_a_survivor(self):
        exemption = {"id": "/subscriptions/example/resourceGroups/rg-alz-image-build/providers/Microsoft.Authorization/policyExemptions/packer-image", "name": "packer-image", "expiresOn": "2020-01-01T00:00:00Z"}
        with patch.object(verify, "query", side_effect=[[], [], [exemption]]):
            self.assertEqual(verify.main(), 1)

    def test_unrelated_resource_is_preserved(self):
        vm = {"resourceGroup": "rg-other-compute", "type": "Microsoft.Compute/virtualMachines", "name": "other-vm"}
        with patch.object(verify, "query", side_effect=[[vm], [], []]):
            self.assertEqual(verify.main(), 0)

    def test_nested_gallery_storage_is_a_survivor(self):
        gallery = {"resourceGroup": "rg-alz-images", "type": "Microsoft.Compute/galleries", "name": "galalz"}
        # The top-level inventory omits the billed version, as Azure can do.
        with patch.object(verify, "query", side_effect=[
            [gallery], [], [], [{"name": "hardened-ubuntu-2204"}], [{"name": "1.0.0"}]
        ]):
            self.assertEqual(verify.main(), 1)

    def test_unrelated_denial_does_not_prove_compute_control(self):
        result = subprocess.CompletedProcess([], 1, "", "RequestDisallowedByPolicy /policyAssignments/require-tag")
        self.assertFalse(policy.is_denial(result, "approved-vm-images"))

    def test_authorization_error_does_not_prove_policy(self):
        result = subprocess.CompletedProcess([], 1, "", "AuthorizationFailed /policyAssignments/approved-vm-images")
        self.assertFalse(policy.is_denial(result, "approved-vm-images"))

    def test_expected_policy_denial_passes(self):
        result = subprocess.CompletedProcess([], 1, "", "RequestDisallowedByPolicy /policyAssignments/approved-vm-images")
        self.assertTrue(policy.is_denial(result, "approved-vm-images"))


if __name__ == "__main__":
    unittest.main()
