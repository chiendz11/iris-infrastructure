"""Offline tests of path policy, real YAML DAG conditions, and trust boundaries.

The DAG simulator evaluates the small expression subset used by this repo, not
the GitHub scheduler. actionlint separately checks Actions syntax/contracts.
"""
from __future__ import annotations

import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import yaml

from scripts.plan_production import changed_paths, classify, select

ROOT = Path(__file__).resolve().parents[1]
WORKFLOWS = ROOT / ".github/workflows"


def workflow(name):
    # BaseLoader preserves 'on' instead of parsing it as a YAML 1.1 boolean.
    return yaml.load((WORKFLOWS / name).read_text(), Loader=yaml.BaseLoader)


def simulate(paths=(), *, scope="", overrides=None, domain_changed=False, delegated=True,
             role_changed=False, cancelled=False):
    selected = select(list(paths), mode="manual" if scope else "push", scope=scope)
    outputs = {
        "select": {key: str(value).lower() for key, value in selected.items()},
        "foundation": {"apply_role_changed": str(role_changed).lower()},
        "domain": {"delegation_required": str(not delegated).lower(),
                   "previous_platform_signature": "before",
                   "zone_platform_signature": "after" if domain_changed else "before"},
    }
    statuses = {}
    for name, job in workflow("production-infra.yml")["jobs"].items():
        needs = job.get("needs", [])
        needs = [needs] if isinstance(needs, str) else needs
        results = [statuses[key] for key in needs]
        expression = job.get("if", "true")
        # GitHub applies implicit success() unless a status-check fn appears.
        runnable = all(status == "success" for status in results)
        if "cancelled()" in expression:
            runnable = True
        expression = expression.removeprefix("${{").removesuffix("}}").strip()
        expression = expression.replace("github.ref", repr("refs/heads/main"))
        expression = expression.replace("needs.*.result", repr(results))
        expression = expression.replace("cancelled()", repr(cancelled))
        expression = re.sub(
            r"needs\.([\w-]+)\.outputs\.([\w_]+)",
            lambda match: repr(outputs.get(match[1], {}).get(match[2], "")
                               if statuses.get(match[1]) == "success" else ""), expression)
        expression = re.sub(r"needs\.([\w-]+)\.result",
                            lambda match: repr(statuses.get(match[1], "")), expression)
        expression = re.sub(r"!(?!=)", " not ", expression)
        expression = expression.replace("&&", " and ").replace("||", " or ")
        # Expression comes only from version-controlled YAML, not user payload.
        runnable = runnable and bool(eval(f"({expression})", {"__builtins__": {}}, {
            "contains": lambda sequence, item: item in sequence, "true": True,
        }))
        statuses[name] = (overrides or {}).get(name, "success") if runnable else "skipped"
    return statuses


class PathPolicyTest(unittest.TestCase):
    def test_docs_and_tests_do_not_apply(self):
        for path in ["README.md", "docs/AWS_DEPLOYMENT.md", "tests/test_example.py",
                     "requirements-ci.txt", ".github/workflows/terraform.yml"]:
            self.assertFalse(any(classify([path]).values()), path)

    def test_root_and_helper_mapping(self):
        for path, root in [
            ("terraform/bootstrap/main.tf", "foundation"),
            ("terraform/github-governance/main.tf", "governance"),
            ("terraform/github-config/main.tf", "github_config"),
            ("terraform/domain/main.tf", "domain"),
            ("terraform/platform/eks.tf", "platform"),
            ("environments/production.tfvars", "platform"),
            ("scripts/wait-for-dns-delegation.sh", "domain"),
            ("scripts/migrate-rulesets.sh", "governance"),
            (".github/workflows/reusable-platform.yml", "platform"),
        ]:
            self.assertEqual([key for key, value in classify([path]).items() if value], [root])

    def test_shared_orchestration_change_reviews_all_roots(self):
        for path in ["scripts/plan_production.py", ".github/workflows/production-infra.yml"]:
            self.assertTrue(all(classify([path]).values()))

    def test_foundation_propagates_config_but_not_dns(self):
        result = select(["terraform/bootstrap/main.tf"], mode="push")
        self.assertTrue(result["foundation"] and result["github_config"])
        self.assertFalse(result["domain"] or result["platform"])
        self.assertFalse(select(["terraform/bootstrap/main.tf"], mode="pr")["github_config"])

    def test_manual_scope_rejects_arbitrary_input(self):
        with self.assertRaises(ValueError):
            select([], mode="manual", scope="../../other-account")

    def test_initial_push_and_moves_are_not_missed(self):
        with patch("scripts.plan_production.subprocess.check_output", return_value="README.md\0") as git:
            self.assertEqual(changed_paths("0" * 40, "a" * 40), ["README.md"])
            self.assertIn("ls-tree", git.call_args.args[0])
            changed_paths("b" * 40, "a" * 40)
            self.assertIn("--no-renames", git.call_args.args[0])
        with self.assertRaises(ValueError):
            changed_paths("--bad-revision", "a" * 40)


class DagTest(unittest.TestCase):
    def test_platform_only_survives_skipped_upstreams(self):
        states = simulate(["terraform/platform/eks.tf"])
        for name in ["foundation", "governance", "github-config-before", "domain", "request-certificate"]:
            self.assertEqual(states[name], "skipped")
        for name in ["platform", "github-config-after", "handoff"]:
            self.assertEqual(states[name], "success")

    def test_foundation_only_does_not_revisit_dns(self):
        states = simulate(scope="foundation")
        self.assertEqual(states["github-config-before"], "success")
        self.assertEqual(states["domain"], "skipped")
        self.assertEqual(states["platform"], "skipped")
        self.assertEqual(simulate(scope="foundation", role_changed=True)["platform"], "success")

    def test_initial_dns_handoff_blocks_platform(self):
        states = simulate(scope="all", delegated=False, domain_changed=True)
        self.assertEqual(states["request-certificate"], "success")
        for name in ["platform", "github-config-after", "handoff"]:
            self.assertEqual(states[name], "skipped")

    def test_domain_only_runs_platform_when_consumed_output_changes(self):
        self.assertEqual(simulate(scope="domain")["platform"], "skipped")
        self.assertEqual(simulate(scope="domain", domain_changed=True)["platform"], "success")

    def test_simultaneous_domain_and_platform_has_one_apply(self):
        states = simulate(["terraform/domain/main.tf", "terraform/platform/eks.tf"])
        self.assertEqual(states["domain"], "success")
        self.assertEqual(states["platform"], "success")
        self.assertEqual(states["request-certificate"], "skipped")

    def test_failed_or_cancelled_upstream_never_deploys(self):
        for upstream in ["foundation", "governance", "github-config-before", "domain"]:
            for result in ["failure", "cancelled"]:
                states = simulate(scope="all", overrides={upstream: result})
                self.assertEqual(states["platform"], "skipped", (upstream, result))
                self.assertEqual(states["handoff"], "skipped", (upstream, result))
        self.assertEqual(simulate(scope="platform", cancelled=True)["platform"], "skipped")

    def test_platform_or_config_failure_blocks_handoff(self):
        for upstream in ["platform", "github-config-after"]:
            self.assertEqual(simulate(scope="platform", overrides={upstream: "failure"})["handoff"], "skipped")

    def test_handoff_only_does_not_apply_platform(self):
        states = simulate(scope="handoff")
        self.assertEqual(states["platform"], "skipped")
        self.assertEqual(states["github-config-after"], "success")
        self.assertEqual(states["handoff"], "success")

    def test_docs_only_mutates_nothing(self):
        states = simulate(["README.md"])
        self.assertTrue(all(value == "skipped" for key, value in states.items() if key != "select"))


class WorkflowBoundaryTest(unittest.TestCase):
    def test_reusables_have_no_triggers_routes_or_nested_deployment_lock(self):
        for path in WORKFLOWS.glob("reusable-*.yml"):
            doc = workflow(path.name)
            self.assertEqual(set(doc["on"]), {"workflow_call"})
            self.assertNotIn("concurrency", doc)
            self.assertNotIn("route", doc["jobs"])
            for job in doc["jobs"].values():
                self.assertEqual(job["environment"], "prod")
                self.assertEqual(job["permissions"]["id-token"], "write")
                self.assertNotIn("actions", job["permissions"])
                steps = job["steps"]
                guard = next(i for i, step in enumerate(steps) if "assert-current-main.sh" in step.get("run", ""))
                credentials = next(i for i, step in enumerate(steps)
                                   if "configure-aws-credentials@" in step.get("uses", "") or
                                   "create-github-app-token@" in step.get("uses", ""))
                self.assertLess(guard, credentials)
            if path.name != "reusable-platform-handoff.yml":
                self.assertNotIn("gh workflow run", path.read_text())

    def test_handoff_is_trusted_state_not_caller_contract(self):
        doc = workflow("reusable-platform-handoff.yml")
        self.assertEqual(set(doc["on"]["workflow_call"]["inputs"]), {"foundation"})
        text = (WORKFLOWS / "reusable-platform-handoff.yml").read_text()
        self.assertNotIn("terraform apply", text)
        self.assertIn("-detailed-exitcode", text)
        self.assertIn('if [[ "${result}" != 0 ]]', text)
        self.assertIn("terraform -chdir=terraform/platform output -json", text)
        self.assertIn("aws secretsmanager describe-secret", text)
        self.assertNotIn("get-secret-value", text)
        self.assertIn("permission-actions: write", text)
        self.assertIn("gh workflow run platform-reconcile.yml", text)

    def test_no_double_ingress_and_same_revision_reuse(self):
        push_workflows = [path.name for path in WORKFLOWS.glob("*.yml") if "push" in workflow(path.name)["on"]]
        self.assertEqual(push_workflows, ["production-infra.yml"])
        for job in workflow("production-infra.yml")["jobs"].values():
            if "uses" in job:
                self.assertTrue(job["uses"].startswith("./.github/workflows/reusable-"))
                self.assertNotIn("@main", job["uses"])
                self.assertNotIn("secrets", job)  # job-scoped prod secrets, no blanket inherit


class RevisionGuardTest(unittest.TestCase):
    def test_main_freshness_and_boundary(self):
        with tempfile.TemporaryDirectory() as directory:
            mock = Path(directory) / "git"
            mock.write_text('#!/bin/sh\nif [ "$1" = rev-parse ]; then echo "$TEST_LOCAL_SHA"; else printf "%s\\trefs/heads/main\\n" "$TEST_REMOTE_SHA"; fi\n')
            mock.chmod(0o755)
            env = dict(os.environ, PATH=f"{directory}:{os.defpath}",
                       GITHUB_REPOSITORY="chiendz11/iris-infrastructure", GITHUB_REF="refs/heads/main",
                       GITHUB_EVENT_NAME="push", GITHUB_SHA="a" * 40,
                       TEST_LOCAL_SHA="a" * 40, TEST_REMOTE_SHA="a" * 40, EXPECTED_SHA="")
            for overrides, success in [({}, True), ({"GITHUB_EVENT_NAME": "workflow_dispatch"}, True),
                                       ({"TEST_REMOTE_SHA": "b" * 40}, False),
                                       ({"TEST_LOCAL_SHA": "b" * 40}, False),
                                       ({"EXPECTED_SHA": "b" * 40}, False),
                                       ({"GITHUB_REF": "refs/heads/feat"}, False),
                                       ({"GITHUB_EVENT_NAME": "pull_request"}, False),
                                       ({"GITHUB_REPOSITORY": "other/iris-infrastructure"}, False)]:
                result = subprocess.run(["bash", str(ROOT / "scripts/assert-current-main.sh")],
                                        env=env | overrides, capture_output=True, text=True, timeout=5)
                self.assertEqual(result.returncode == 0, success, (overrides, result.stderr))


class DomainPreflightTest(unittest.TestCase):
    def run_guard(self, overrides):
        with tempfile.TemporaryDirectory() as directory:
            mock = Path(directory) / "terraform"
            mock.write_text('''#!/bin/sh
if [ "$2" = init ]; then exit "${TEST_INIT_EXIT:-0}"; fi
if [ "$4" = domain_ready ]; then echo "$TEST_READY"; else echo "$TEST_DOMAIN"; fi
''')
            mock.chmod(0o755)
            env = dict(os.environ, PATH=f"{directory}:{os.defpath}",
                       TF_VAR_enable_public_domain="true", PUBLIC_DOMAIN_NAME="example.com",
                       TF_VAR_state_bucket_name="mock", AWS_REGION="ap-southeast-1",
                       TF_VAR_state_kms_key_arn="mock", TEST_READY="true", TEST_DOMAIN="Example.COM.")
            return subprocess.run(["bash", str(ROOT / "scripts/require-domain-ready.sh")],
                                  env=env | overrides, text=True, capture_output=True, timeout=5)

    def test_ready_matching_domain_and_disabled_mode(self):
        self.assertEqual(self.run_guard({}).returncode, 0)
        self.assertEqual(self.run_guard({"TF_VAR_enable_public_domain": "false", "TEST_INIT_EXIT": "1"}).returncode, 0)

    def test_unready_mismatched_or_inaccessible_state_blocks(self):
        for overrides in [{"TEST_READY": "false"}, {"TEST_DOMAIN": "other.example"}, {"TEST_INIT_EXIT": "1"}]:
            self.assertNotEqual(self.run_guard(overrides).returncode, 0)


class ConfigDiscoveryTest(unittest.TestCase):
    def test_only_not_found_means_no_platform_state(self):
        job = workflow("reusable-github-config.yml")["jobs"]["apply-github-config"]
        code = next(step["run"] for step in job["steps"]
                    if step.get("name") == "Detect platform state and validate publisher identities")
        code = re.sub(r"\$\{\{.*?\}\}", "mock-bucket", code)
        with tempfile.TemporaryDirectory() as directory:
            mock = Path(directory) / "aws"
            mock.write_text('#!/bin/sh\nprintf "%s\\n" "$TEST_AWS_ERROR" >&2\nexit 1\n')
            mock.chmod(0o755)
            for message, allowed in [("An error occurred (404): Not Found", True),
                                     ("An error occurred (403): Forbidden", False),
                                     ("Unable to locate credentials", False),
                                     ("Connection timed out", False)]:
                env = dict(os.environ, PATH=f"{directory}:{os.defpath}", RUNNER_TEMP=directory,
                           GITHUB_ENV=f"{directory}/env", TEST_AWS_ERROR=message)
                result = subprocess.run(["bash", "-e", "-o", "pipefail", "-c", code],
                                        env=env, text=True, capture_output=True, timeout=5)
                self.assertEqual(result.returncode == 0, allowed, result.stderr)


if __name__ == "__main__":
    unittest.main()
