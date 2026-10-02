"""Prevent unschedulable Redis HA pods caused by a nonexistent node label."""

from pathlib import Path
import unittest

import yaml


ROOT = Path(__file__).resolve().parents[1]


class ArgoCdHaTopologyTests(unittest.TestCase):
    def test_redis_ha_spreads_across_the_standard_hostname_label(self):
        values = yaml.safe_load(
            (ROOT / "terraform/platform/argocd-values-production.yaml").read_text()
        )
        topology = values["redis-ha"]["topologySpreadConstraints"]

        self.assertTrue(topology["enabled"])
        self.assertEqual(topology["topologyKey"], "kubernetes.io/hostname")
        self.assertEqual(topology["whenUnsatisfiable"], "DoNotSchedule")

    def test_nonexistent_hostname_topology_label_is_not_used(self):
        source = (
            ROOT / "terraform/platform/argocd-values-production.yaml"
        ).read_text()

        self.assertNotIn("topology.kubernetes.io/hostname", source)


if __name__ == "__main__":
    unittest.main()
