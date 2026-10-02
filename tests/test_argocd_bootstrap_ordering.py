"""Ensure Argo CD CRDs exist before Terraform installs the root Application."""

from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]


class ArgoCdBootstrapOrderingTests(unittest.TestCase):
    def test_controller_and_root_are_separate_ordered_releases(self):
        source = (ROOT / "terraform/platform/gitops_controller.tf").read_text()

        self.assertIn('resource "helm_release" "argocd"', source)
        self.assertIn('resource "helm_release" "argocd_root"', source)
        self.assertIn('chart     = "${path.module}/charts/argocd-root"', source)
        self.assertIn("depends_on = [helm_release.argocd]", source)
        self.assertNotIn("extraObjects", source)
        self.assertNotIn("argocd-root-application-values.yaml", source)

    def test_root_chart_contains_only_the_application_custom_resource(self):
        chart = ROOT / "terraform/platform/charts/argocd-root"
        template = (chart / "templates/application.yaml").read_text()
        values = (chart / "values.yaml").read_text()

        self.assertTrue((chart / "Chart.yaml").is_file())
        self.assertIn("apiVersion: argoproj.io/v1alpha1", template)
        self.assertIn("kind: Application", template)
        self.assertIn("name: iris-production", values)
        self.assertNotIn("CustomResourceDefinition", template)


if __name__ == "__main__":
    unittest.main()
