# Terraform owns only the Secrets Manager container and access policy. The GitHub
# App private key is seeded out of band, so it never appears in Terraform state.
resource "aws_secretsmanager_secret" "model_promotion_github_app" {
  name                    = "${local.name}/github-app/model-promoter"
  description             = "GitHub App credential used to dispatch release intents and open protected GitOps PRs"
  recovery_window_in_days = 30

  tags = {
    Workload = "model-promotion"
  }
}
