"""Offline regression tests: no AWS/GitHub credentials or network are used."""
from __future__ import annotations

import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]


class SoloAutomationTest(unittest.TestCase):
    def setUp(self) -> None:
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.temp = Path(self.directory.name)
        self.bin = self.temp / "bin"
        self.bin.mkdir()
        self.env = {
            "PATH": f"{self.bin}:{os.defpath}",
            "GITHUB_REPOSITORY": "chiendz11/iris-infrastructure",
            "TEST_LOG": str(self.temp / "calls.jsonl"),
            "TEST_COUNT": str(self.temp / "count"),
        }

    def mock_command(self, name: str, code: str) -> None:
        path = self.bin / name
        path.write_text("#!/usr/bin/env python3\n" + code)
        path.chmod(0o755)

    def run_script(self, script: str, *args: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            ["bash", str(ROOT / "scripts" / script), *args],
            env=self.env, text=True, capture_output=True, timeout=5,
        )

    def mock_github(self) -> None:
        self.mock_command("gh", '''import json, os, sys
from pathlib import Path
args = sys.argv[1:]
payload = json.load(sys.stdin) if "--input" in args else None
with open(os.environ["TEST_LOG"], "a") as log:
    log.write(json.dumps({"args": args, "payload": payload}) + "\\n")
if args[0] == "variable":
    sys.exit(0)
if args[1].startswith("users/"):
    print(json.dumps({"id": 12345, "login": args[1].split("/")[1],
                      "type": os.environ.get("OWNER_TYPE", "User")}))
elif "--method" in args:
    print("{}")
elif args[1].endswith("/rulesets"):
    print("123")
else:
    repo = args[1].split("/")[2]
    check = {"iris-infrastructure":"pr-gate", "iris-gitops":"validate"}.get(repo, "ci-gate")
    required_type = os.environ.get("REQUIRED_CHECK_TYPE", "required_status_checks")
    print(json.dumps({"enforcement":"active", "conditions":{"ref_name":{"include":["~DEFAULT_BRANCH"]}},
      "rules":[{"type":"deletion"}, {"type":"non_fast_forward"}, {"type":"required_linear_history"},
        {"type":"pull_request", "parameters":{
          "dismiss_stale_reviews_on_push":True, "require_code_owner_review":False,
          "require_last_push_approval":False, "required_approving_review_count":int(os.environ.get("REVIEWS", "0")),
          "required_review_thread_resolution":True}},
        {"type":required_type, "parameters":{"strict_required_status_checks_policy":True,
          "required_status_checks":[{"context":check, "integration_id":15368}]}}]}))
''')

    def calls(self) -> list[dict]:
        path = Path(self.env["TEST_LOG"])
        return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []

    def test_environment_requires_owner_and_allows_self_approval(self) -> None:
        self.mock_github()
        result = self.run_script("configure-solo-environment.sh")
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = self.calls()
        self.assertEqual(len(calls), 2)
        self.assertEqual(calls[0]["args"], ["api", "users/chiendz11"])
        self.assertEqual(calls[1]["args"], ["api", "--method", "PUT", "repos/chiendz11/iris-infrastructure/environments/prod", "--input", "-"])
        self.assertEqual(calls[1]["payload"], {
            "wait_timer": 0, "prevent_self_review": False, "can_admins_bypass": False,
            "reviewers": [{"type": "User", "id": 12345}], "deployment_branch_policy": {
                "protected_branches": True, "custom_branch_policies": False,
            },
        })

    def test_environment_refuses_nonhuman_owner_before_mutation(self) -> None:
        self.mock_github()
        self.env["OWNER_TYPE"] = "Organization"
        result = self.run_script("configure-solo-environment.sh")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("no Environment was changed", result.stderr)
        self.assertEqual(len(self.calls()), 1)
        self.assertFalse(any("--method" in call["args"] for call in self.calls()))

    def test_environment_refuses_app_repo_owned_by_terraform(self) -> None:
        self.mock_github()
        self.env["GITHUB_REPOSITORY"] = "chiendz11/iris-inference-service"
        self.assertNotEqual(self.run_script("configure-solo-environment.sh").returncode, 0)
        self.assertEqual(self.calls(), [])

    def test_day_zero_no_longer_requires_or_publishes_reviewer_metadata(self) -> None:
        self.mock_github()
        self.mock_command("terraform", 'print("test-output")\n')
        result = self.run_script("configure-github.sh", "example.com", "")
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = self.calls()
        variables = [call["args"][2] for call in calls if call["args"][0] == "variable"]
        self.assertIn("TERRAFORM_APPLY_ROLE_ARN", variables)
        self.assertNotIn("PRODUCTION_REVIEWER_USERNAMES_JSON", variables)
        self.assertFalse(any("collaborators" in str(call) for call in calls))

    def test_ruleset_verifier_accepts_solo_and_never_mutates_in_verify_mode(self) -> None:
        self.mock_github()
        result = self.run_script("migrate-rulesets.sh")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(self.calls()), 10)
        self.assertFalse(any("--method" in call["args"] for call in self.calls()))

    def test_ruleset_verifier_rejects_old_review_requirement(self) -> None:
        self.mock_github()
        self.env["REVIEWS"] = "1"
        result = self.run_script("migrate-rulesets.sh", "--remove-legacy")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(any("DELETE" in call["args"] for call in self.calls()))

    def test_ruleset_verifier_still_requires_ci(self) -> None:
        self.mock_github()
        self.env["REQUIRED_CHECK_TYPE"] = "wrong_type"
        self.assertNotEqual(self.run_script("migrate-rulesets.sh").returncode, 0)

    def mock_dns(self, answers: list[str]) -> None:
        self.env.update(DNS_MAX_ATTEMPTS="2", DNS_RETRY_SECONDS="1", DNS_ANSWERS=json.dumps(answers))
        self.mock_command("dig", '''import json, os
from pathlib import Path
counter = Path(os.environ["TEST_COUNT"])
index = int(counter.read_text()) if counter.exists() else 0
counter.write_text(str(index + 1))
answers = json.loads(os.environ["DNS_ANSWERS"])
print(answers[min(index, len(answers)-1)])
''')
        self.mock_command("sleep", "pass\n")

    def test_dns_accepts_normalized_ns_sets(self) -> None:
        self.mock_dns(["NS2.AWSDNS.NET.\nns1.awsdns.com."])
        result = self.run_script("wait-for-dns-delegation.sh", "example.com", '["ns1.awsdns.com", "ns2.awsdns.net"]')
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_dns_retries_then_continues_only_when_matching(self) -> None:
        self.mock_dns(["wrong.example.net.", "ns1.awsdns.com."])
        result = self.run_script("wait-for-dns-delegation.sh", "example.com", '["ns1.awsdns.com"]')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(Path(self.env["TEST_COUNT"]).read_text(), "2")

    def test_dns_timeout_fails_closed(self) -> None:
        self.mock_dns([""])
        result = self.run_script("wait-for-dns-delegation.sh", "example.com", '["ns1.awsdns.com"]')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("rerun terraform-domain-certificate.yml", result.stderr)

    def test_dns_rejects_empty_expected_set(self) -> None:
        self.mock_dns([""])
        self.assertNotEqual(self.run_script("wait-for-dns-delegation.sh", "example.com", "[]").returncode, 0)
        self.assertFalse(Path(self.env["TEST_COUNT"]).exists())

    def test_dns_rejects_unbounded_polling(self) -> None:
        self.mock_dns([""])
        self.env["DNS_MAX_ATTEMPTS"] = "999"
        self.assertNotEqual(self.run_script("wait-for-dns-delegation.sh", "example.com", '["ns1.awsdns.com"]').returncode, 0)

    def test_terraform_and_workflows_do_not_reenable_stale_reviewers(self) -> None:
        for file in ["terraform/github-config/main.tf", "terraform/github-config/variables.tf",
                     ".github/workflows/terraform.yml", ".github/workflows/reusable-github-config.yml"]:
            text = (ROOT / file).read_text()
            self.assertNotIn("production_reviewer_usernames", text)
            self.assertNotIn("PRODUCTION_REVIEWER_USERNAMES_JSON", text)
        text = (ROOT / "terraform/github-config/main.tf").read_text()
        self.assertIn('data "github_user" "deployment_approver"', text)
        self.assertIn("username = var.github_owner", text)
        self.assertIn("reviewers {", text)
        self.assertIn("tonumber(data.github_user.deployment_approver[0].id)", text)
        self.assertIn("prevent_self_review = false", text)
        self.assertIn("prevent_destroy = true", text)

    def test_dns_script_changes_follow_domain_dependency_routing(self) -> None:
        from scripts.plan_production import classify
        self.assertTrue(classify(["scripts/wait-for-dns-delegation.sh"])["domain"])
        for file in ["terraform.yml", "production-infra.yml"]:
            self.assertIn("scripts/plan_production.py", (ROOT / ".github/workflows" / file).read_text())

    def test_certificate_has_distinct_run_but_uses_existing_prod_environment(self) -> None:
        zone = (ROOT / ".github/workflows/production-infra.yml").read_text()
        cert = (ROOT / ".github/workflows/terraform-domain-certificate.yml").read_text()
        self.assertNotIn("  apply-domain-certificate:", zone)
        self.assertIn("gh workflow run terraform-domain-certificate.yml", zone)
        self.assertIn("if: needs.domain.outputs.delegation_required == 'true'", zone)
        self.assertIn("needs: domain", zone)
        self.assertIn("workflow_dispatch:", cert)
        self.assertIn("if: github.ref == 'refs/heads/main'", cert)
        called = (ROOT / ".github/workflows/reusable-certificate.yml").read_text()
        self.assertEqual(called.count("environment: prod"), 1)
        self.assertIn("needs: certificate", cert)
        self.assertIn("uses: ./.github/workflows/reusable-certificate.yml", cert)
        self.assertIn("--field scope=platform", cert)
        self.assertNotIn("always()", cert)
        self.assertIn("cancel-in-progress: false", cert)

    def test_certificate_reads_state_and_verifies_dns_before_acm(self) -> None:
        cert = (ROOT / ".github/workflows/reusable-certificate.yml").read_text()
        self.assertLess(cert.index("terraform init"), cert.index("terraform output -json route53_name_servers"))
        self.assertLess(cert.index("terraform output -json route53_name_servers"), cert.index("bash scripts/wait-for-dns-delegation.sh"))
        self.assertLess(cert.index("bash scripts/wait-for-dns-delegation.sh"), cert.index("terraform plan -out=tfplan"))
        self.assertIn('${STATE_DOMAIN,,}" == "${CONFIGURED_DOMAIN,,}', cert)
        self.assertIn('TF_VAR_domain_delegated: "true"', cert)
        self.assertIn('test "$(terraform output -raw domain_ready)" = "true"', cert)

    def test_certificate_workflow_changes_follow_domain_dependency_routing(self) -> None:
        from scripts.plan_production import classify
        for name in ["terraform-domain-certificate.yml", "reusable-certificate.yml"]:
            self.assertTrue(classify([f".github/workflows/{name}"])["domain"])


if __name__ == "__main__":
    unittest.main()
