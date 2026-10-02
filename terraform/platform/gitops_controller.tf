provider "helm" {
  kubernetes = {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
    exec = {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args = [
        "eks",
        "get-token",
        "--cluster-name",
        module.eks.cluster_name,
        "--region",
        var.aws_region
      ]
    }
  }
}

resource "helm_release" "argocd" {
  name       = "argocd"
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argo-cd"
  version    = trimspace(file("${path.module}/argocd-chart-version.txt"))

  namespace        = "argocd"
  create_namespace = true

  atomic            = true
  cleanup_on_fail   = true
  dependency_update = false
  max_history       = 10
  timeout           = 900
  wait              = true
  wait_for_jobs     = true

  values = [
    file("${path.module}/argocd-values-production.yaml")
  ]

  # The EKS module includes the managed node group and the explicit Access
  # Entry that authorizes the protected Terraform apply role.
  depends_on = [module.eks, aws_eks_addon.ebs_csi]
}

# A Custom Resource cannot be submitted until the API server has registered its
# CRD. Keep the root Application in a second Helm release so the Argo CD chart
# installs and establishes applications.argoproj.io before Helm validates this
# manifest. Terraform remains the owner of both releases.
resource "helm_release" "argocd_root" {
  name      = "iris-root"
  chart     = "${path.module}/charts/argocd-root"
  namespace = "argocd"

  atomic            = true
  cleanup_on_fail   = true
  dependency_update = false
  max_history       = 10
  timeout           = 300
  wait              = true

  depends_on = [helm_release.argocd]
}
