from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]


class PlatformIamNameTest(unittest.TestCase):
    def test_load_balancer_controller_uses_a_stable_role_name(self):
        edge = (ROOT / "terraform/platform/edge.tf").read_text()

        self.assertIn(
            'aws_load_balancer_controller_role_name = "${local.name}-aws-load-balancer-controller"',
            edge,
        )
        self.assertIn("use_name_prefix", edge)
        self.assertRegex(edge, r"use_name_prefix\s*=\s*false")
        self.assertIn('length(local.aws_load_balancer_controller_role_name) <= 64', edge)


if __name__ == "__main__":
    unittest.main()
