# Terraform owns only the Secrets Manager containers and access policies. GitHub
# App private keys are seeded out of band, so they never appear in Terraform state.
resource "aws_secretsmanager_secret" "model_release_publisher_github_app" {
  name                    = "${local.name}/github-app/model-release-publisher"
  description             = "Actions-only GitHub App credential used by the in-cluster model-release publisher"
  recovery_window_in_days = 30

  tags = {
    Workload = "model-release-publisher"
  }
}

resource "aws_secretsmanager_secret" "gitops_automation_github_app" {
  name                    = "${local.name}/github-app/gitops-automation"
  description             = "GitHub App credential used only by trusted GitOps renderers to open protected desired-state PRs"
  recovery_window_in_days = 30

  tags = {
    Workload = "gitops-automation"
  }
}
