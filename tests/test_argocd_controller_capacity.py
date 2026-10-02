"""Keep the production Argo CD controller viable on the small EKS profile."""

from pathlib import Path
import unittest

import yaml


ROOT = Path(__file__).resolve().parents[1]


class ArgoCdControllerCapacityTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.values = yaml.safe_load(
            (ROOT / "terraform/platform/argocd-values-production.yaml").read_text()
        )

    def test_controller_has_headroom_for_platform_crd_discovery(self):
        resources = self.values["controller"]["resources"]

        self.assertEqual(resources["requests"]["memory"], "1Gi")
        self.assertEqual(resources["limits"]["memory"], "2Gi")

    def test_controller_concurrency_is_bounded_for_the_demo_cluster(self):
        params = self.values["configs"]["params"]

        self.assertEqual(params["controller.status.processors"], "5")
        self.assertEqual(params["controller.operation.processors"], "3")
        self.assertEqual(params["controller.kubectl.parallelism.limit"], "5")


if __name__ == "__main__":
    unittest.main()
