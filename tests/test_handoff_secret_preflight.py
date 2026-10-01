"""Execute the handoff preflight with fake AWS metadata, never real secrets."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

import yaml


ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github/workflows/reusable-platform-handoff.yml"


class HandoffSecretPreflightTest(unittest.TestCase):
    def preflight(self, model_stages, automation_stages, *, aws_error=""):
        workflow = yaml.safe_load(WORKFLOW.read_text())
        steps = next(iter(workflow["jobs"].values()))["steps"]
        code = next(step["run"] for step in steps
                    if step.get("name") == "Verify runtime GitHub App credentials are seeded")
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory)
            aws = folder / "aws"
            aws.write_text('''#!/bin/sh
set -eu
[ "$1 $2" = "secretsmanager describe-secret" ] || exit 99
printf '%s\\n' "$*" >> "$TEST_AWS_CALLS"
if [ -n "$TEST_AWS_ERROR" ]; then
  printf '%s\\n' "$TEST_AWS_ERROR" >&2
  exit 1
fi
case "$4" in
  model-secret-arn) printf '%s\\n' "$TEST_MODEL_STAGES" ;;
  automation-secret-arn) printf '%s\\n' "$TEST_AUTOMATION_STAGES" ;;
  *) exit 98 ;;
esac
''')
            aws.chmod(0o755)
            (folder / "terraform-outputs.json").write_text(json.dumps({
                "model_release_publisher_github_app_secret_arn": {"value": "model-secret-arn"},
                "gitops_automation_github_app_secret_arn": {"value": "automation-secret-arn"},
            }))
            summary, calls = folder / "summary", folder / "calls"
            env = dict(os.environ, PATH=f"{directory}:{os.defpath}",
                       GITHUB_STEP_SUMMARY=str(summary), TEST_AWS_CALLS=str(calls),
                       TEST_MODEL_STAGES=json.dumps(model_stages),
                       TEST_AUTOMATION_STAGES=json.dumps(automation_stages),
                       TEST_AWS_ERROR=aws_error)
            result = subprocess.run(["bash", "-e", "-o", "pipefail", "-c", code],
                                    cwd=folder, env=env, text=True, capture_output=True, timeout=5)
            return result, summary.read_text() if summary.exists() else "", calls.read_text()

    def test_current_versions_pass_using_metadata_only(self):
        result, summary, calls = self.preflight({"v1": ["AWSCURRENT"]}, {"v2": ["AWSCURRENT"]})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(summary, "")
        self.assertEqual(calls.count("secretsmanager describe-secret"), 2)
        self.assertNotIn("get-secret-value", calls)

    def test_empty_or_previous_versions_block_with_readable_recovery_steps(self):
        for stages in (None, {}, {"old": ["AWSPREVIOUS"]}):
            with self.subTest(stages=stages):
                result, summary, calls = self.preflight(stages, stages)
                self.assertEqual(result.returncode, 1)
                self.assertIn("- model-release-publisher\n", summary)
                self.assertIn("- gitops-automation\n", summary)
                self.assertIn("scripts/seed-github-app-secret.sh", summary)
                self.assertIn("scope=handoff", summary)
                self.assertNotIn("get-secret-value", calls)

    def test_only_the_missing_app_is_reported(self):
        result, summary, _ = self.preflight({"v1": ["AWSCURRENT"]}, {"v2": ["AWSPENDING"]})
        self.assertEqual(result.returncode, 1)
        self.assertIn("- gitops-automation\n", summary)
        self.assertNotIn("- model-release-publisher", summary)

    def test_aws_access_error_fails_instead_of_claiming_an_unseeded_secret(self):
        result, summary, _ = self.preflight({}, {}, aws_error="AccessDeniedException")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("AccessDeniedException", result.stderr)
        self.assertEqual(summary, "")


if __name__ == "__main__":
    unittest.main()
