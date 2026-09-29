"""Offline ownership/wiring checks; no cloud clients or state reads."""
from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parents[1]


class EksStorageTest(unittest.TestCase):
    def test_initial_install_version_is_consistent_across_inputs(self):
        for relative in ("environments/production.tfvars", "terraform/platform/terraform.tfvars.example"):
            source = (ROOT / relative).read_text()
            self.assertRegex(source, r'kubernetes_version\s*=\s*"1\.34"')
        defaults = (ROOT / "terraform/platform/variables.tf").read_text()
        version_block = re.search(r'variable "kubernetes_version"\s*\{([^}]+)\}', defaults)
        self.assertIsNotNone(version_block)
        self.assertRegex(version_block[1], r'default\s*=\s*"1\.34"')

    def test_driver_has_dedicated_scoped_identity_and_ordering(self):
        source = (ROOT / "terraform/platform/eks_storage.tf").read_text()
        self.assertIn('resource "aws_eks_addon" "ebs_csi"', source)
        self.assertIn('"system:serviceaccount:kube-system:ebs-csi-controller-sa"', source)
        self.assertIn('values   = ["sts.amazonaws.com"]', source)
        self.assertIn("module.eks.oidc_provider_arn", source)
        self.assertIn("aws_iam_role.ebs_csi.arn", source)
        self.assertIn('"arn:aws:iam::aws:policy/AmazonEBSCSIDriverPolicyV2"', source)
        self.assertIn("depends_on = [module.eks, aws_iam_role_policy_attachment.ebs_csi]", source)
        self.assertNotIn('resource "aws_ebs_volume"', source)
        self.assertNotIn('resource "kubernetes_', source)
        controller = (ROOT / "terraform/platform/gitops_controller.tf").read_text()
        self.assertIn("depends_on = [module.eks, aws_eks_addon.ebs_csi]", controller)

    def test_addon_can_be_pinned_and_does_not_follow_most_recent(self):
        source = (ROOT / "terraform/platform/eks_storage.tf").read_text()
        self.assertIn("most_recent        = false", source)
        self.assertIn("var.ebs_csi_addon_version != null ? var.ebs_csi_addon_version", source)

    def test_pr_has_no_live_configuration_discovery(self):
        workflow = (ROOT / ".github/workflows/terraform.yml").read_text()
        self.assertIn('TF_VAR_discover_existing_configuration: "false"', workflow)
        apply = (ROOT / ".github/workflows/reusable-github-config.yml").read_text()
        self.assertIn('TF_VAR_discover_existing_configuration: "true"', apply)


if __name__ == "__main__":
    unittest.main()
