"""Static checks for the account-constrained production deployment profile."""

from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]


class AccountConstrainedPlatformProfileTests(unittest.TestCase):
    def test_profile_uses_verified_free_tier_compute(self):
        profile = (ROOT / "environments/production.tfvars").read_text()

        self.assertRegex(
            profile,
            r'(?m)^node_instance_types\s*=\s*\["c7i-flex\.large"\]$',
        )

    def test_profile_respects_rds_free_tier_guards(self):
        profile = (ROOT / "environments/production.tfvars").read_text()

        self.assertRegex(profile, r"(?m)^db_multi_az\s*=\s*false$")
        self.assertRegex(profile, r"(?m)^db_backup_retention_days\s*=\s*1$")
        self.assertRegex(profile, r"(?m)^db_max_allocated_storage\s*=\s*null$")

    def test_rds_retention_is_an_explicit_input(self):
        database = (ROOT / "terraform/platform/database.tf").read_text()
        variables = (ROOT / "terraform/platform/variables.tf").read_text()

        self.assertIn(
            "backup_retention_period   = var.db_backup_retention_days",
            database,
        )
        self.assertIn('variable "db_backup_retention_days"', variables)
        self.assertIn(
            "max_allocated_storage       = var.db_max_allocated_storage",
            database,
        )


if __name__ == "__main__":
    unittest.main()
