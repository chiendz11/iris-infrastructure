"""First-deploy and fail-closed DNS phase tests; no AWS or public DNS calls."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "scripts/detect-domain-delegation.sh"


class DetectDomainDelegationTest(unittest.TestCase):
    def run_detector(self, outputs=None, *, resources="", state_error="", output_error="",
                     dns="", dns_exit=0, enabled="true", raw_outputs=None):
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory)
            terraform = folder / "terraform"
            terraform.write_text('''#!/bin/sh
set -eu
if [ "$1 $2" = "output -json" ] && [ "$#" = 2 ]; then
  if [ -n "$TEST_OUTPUT_ERROR" ]; then echo "$TEST_OUTPUT_ERROR" >&2; exit 1; fi
  printf '%s\\n' "$TEST_OUTPUTS"
elif [ "$1 $2" = "state list" ]; then
  if [ -n "$TEST_STATE_ERROR" ]; then echo "$TEST_STATE_ERROR" >&2; exit 1; fi
  printf '%s\\n' "$TEST_RESOURCES"
else
  # Reproduce Terraform's missing-named-output warning on stdout, not JSON.
  echo 'Warning: No outputs found'
  exit 1
fi
''')
            terraform.chmod(0o755)
            dig = folder / "dig"
            dig.write_text('#!/bin/sh\nprintf "%s\\n" "$TEST_DNS"\nexit "$TEST_DNS_EXIT"\n')
            dig.chmod(0o755)
            env = dict(os.environ, PATH=f"{directory}:{os.defpath}",
                       TEST_OUTPUTS=json.dumps(outputs or {}) if raw_outputs is None else raw_outputs,
                       TEST_OUTPUT_ERROR=output_error, TEST_STATE_ERROR=state_error,
                       TEST_RESOURCES=resources, TEST_DNS=dns, TEST_DNS_EXIT=str(dns_exit))
            return subprocess.run(["bash", str(SCRIPT), enabled, "example.com"],
                                  env=env, cwd=folder, capture_output=True, text=True, timeout=5)

    def zone(self, ready=False):
        return {"domain_name": {"value": "Example.COM."}, "domain_ready": {"value": ready},
                "route53_name_servers": {"value": ["NS1.AWSDNS.COM.", "ns2.awsdns.net"]}}

    def test_first_deploy_with_no_state_returns_false_without_warnings(self):
        result = self.run_detector(state_error="No state file was found!")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "false\n")
        self.assertEqual(result.stderr, "")

    def test_empty_outputs_or_missing_nameservers_without_certificate_return_false(self):
        for outputs in ({}, {"domain_name": {"value": "example.com"}}):
            with self.subTest(outputs=outputs):
                result = self.run_detector(outputs)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout, "false\n")

    def test_matching_normalized_nameservers_return_true(self):
        result = self.run_detector(self.zone(), dns="ns2.awsdns.net.\nns1.awsdns.com.")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "true\n")

    def test_undelegated_zone_without_certificate_returns_false(self):
        result = self.run_detector(self.zone(), dns="ns.registrar.test.")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "false\n")

    def test_dns_drift_with_ready_or_partial_certificate_fails_closed(self):
        for ready, resource in ((True, ""), (False, "aws_acm_certificate.public[0]"),
                                (False, 'aws_route53_record.certificate_validation["example.com"]')):
            with self.subTest(ready=ready, resource=resource):
                result = self.run_detector(self.zone(ready), resources=resource, dns="ns.wrong.test.")
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, "")

    def test_missing_outputs_with_certificate_cannot_reopen_bootstrap(self):
        result = self.run_detector({}, resources="aws_acm_certificate.public[0]")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "")

    def test_state_and_output_errors_fail_instead_of_becoming_false(self):
        for kwargs in ({"state_error": "AccessDenied"}, {"output_error": "AccessDenied"},
                       {"state_error": "connection timeout"}):
            with self.subTest(kwargs=kwargs):
                result = self.run_detector(**kwargs)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, "")

    def test_invalid_json_or_nameserver_type_fails_closed(self):
        for raw in ('Warning: No outputs found\n[]', '[]',
                    '{"route53_name_servers":{"value":"not-an-array"}}',
                    '{"route53_name_servers":{"value":false}}',
                    '{"domain_name":{"value":false}}',
                    '{"domain_ready":{"value":"true"}}'):
            with self.subTest(raw=raw):
                result = self.run_detector(raw_outputs=raw)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, "")

    def test_dns_command_error_fails_closed(self):
        result = self.run_detector(self.zone(), dns_exit=9)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "")

    def test_disabled_domain_does_not_require_backend(self):
        result = self.run_detector(enabled="false", output_error="must not read state")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "false\n")
