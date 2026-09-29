"""Check that offline adoption tests and credential boundaries stay in CI."""
from pathlib import Path
import unittest

import yaml


ROOT = Path(__file__).resolve().parents[1]


class GovernanceAdoptionTest(unittest.TestCase):
    def test_pr_disables_discovery_and_has_no_app_secret(self):
        workflow = yaml.safe_load((ROOT / ".github/workflows/terraform.yml").read_text())
        plan = workflow["jobs"]["plan-governance"]
        step = next(item for item in plan["steps"] if item.get("name", "").startswith("Plan GitHub governance"))
        self.assertEqual(step["env"]["TF_VAR_discover_existing_rulesets"], "false")
        self.assertIn("env -u GITHUB_TOKEN -u GH_TOKEN", step["run"])
        self.assertNotIn("secrets.", str(plan))
        self.assertNotIn("environment", plan)

    def test_protected_job_refreshes_discovers_and_keeps_destructive_guard(self):
        workflow = yaml.safe_load((ROOT / ".github/workflows/reusable-governance.yml").read_text())
        self.assertEqual(workflow["env"]["TF_VAR_discover_existing_rulesets"], "true")
        job = workflow["jobs"]["apply-governance"]
        self.assertEqual(job["environment"], "prod")
        self.assertTrue(any(item.get("name") == "Reject destructive ruleset plans" for item in job["steps"]))

    def test_mock_adoption_suite_runs_in_pr_ci(self):
        workflow = yaml.safe_load((ROOT / ".github/workflows/terraform.yml").read_text())
        self.assertTrue(any(
            item.get("working-directory") == "terraform/github-governance"
            and "terraform test -filter=tests/adoption.tftest.hcl" in item.get("run", "")
            for item in workflow["jobs"]["static"]["steps"]
        ))

    def test_no_historical_ids_are_default_imports(self):
        source = (ROOT / "terraform/github-governance/variables.tf").read_text()
        for old_id in (21312051, 21312006, 21312047, 21312049, 21312050):
            self.assertNotIn(str(old_id), source)
        imports = (ROOT / "terraform/github-governance/import.tf").read_text()
        self.assertIn("for_each = local.import_ruleset_ids", imports)


if __name__ == "__main__":
    unittest.main()
