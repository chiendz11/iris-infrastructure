"""Validate production OIDC inputs without initializing EKS or reading AWS state."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]


class GithubOidcTrustTest(unittest.TestCase):
    def test_platform_scopes_use_exact_configured_prefixes(self):
        source = (ROOT / "terraform/platform/iam.tf").read_text()
        self.assertIn('${var.github_oidc_subject_prefixes[each.value]}:environment:prod', source)
        self.assertEqual(source.count(
            '${var.github_oidc_subject_prefixes[var.gitops_repository]}:ref:refs/heads/main'
        ), 2)
        self.assertNotIn('"repo:${', source)

    @unittest.skipUnless(shutil.which("terraform"), "Terraform CLI is installed by PR CI")
    def test_platform_input_validation_without_any_providers(self):
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory)
            # Copy the actual variables, not duplicated validation logic. No
            # backend, provider, resource or remote state enters this fixture.
            shutil.copy2(ROOT / "terraform/platform/variables.tf", folder / "variables.tf")
            (folder / "tests").mkdir()
            shutil.copy2(ROOT / "tests/fixtures/platform-oidc.tftest.hcl", folder / "tests/oidc.tftest.hcl")
            result = subprocess.run(
                ["terraform", f"-chdir={folder}", "test", "-no-color"],
                capture_output=True, text=True, timeout=30,
            )
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("5 passed, 0 failed", result.stdout)


if __name__ == "__main__":
    unittest.main()
