import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


class EksKmsAdministratorTests(unittest.TestCase):
    def test_kms_administrator_does_not_depend_on_current_caller(self):
        source = (ROOT / "terraform/platform/eks.tf").read_text()

        self.assertIn(
            "kms_key_administrators = [local.terraform_apply_role_arn]",
            source,
        )


if __name__ == "__main__":
    unittest.main()
