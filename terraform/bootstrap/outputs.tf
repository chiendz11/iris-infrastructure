output "state_bucket" {
  value = aws_s3_bucket.terraform_state.bucket
}

output "state_kms_key_arn" {
  value = aws_kms_key.terraform_state.arn
}

output "github_oidc_provider_arn" {
  value = aws_iam_openid_connect_provider.github.arn
}

output "terraform_plan_role_arn" {
  value = aws_iam_role.terraform_plan.arn
}

output "terraform_apply_role_arn" {
  value = aws_iam_role.terraform_apply.arn
}

output "github_governance_plan_role_arn" {
  description = "OIDC role used by credential-free GitHub ruleset speculative plans to read their state."
  value       = aws_iam_role.github_governance_plan.arn
}

output "github_governance_apply_role_arn" {
  description = "OIDC role scoped to the GitHub governance state object; it has no AWS resource administration."
  value       = aws_iam_role.github_governance_apply.arn
}

output "github_config_plan_role_arn" {
  description = "OIDC role used by GitHub configuration speculative plans to read only their state dependencies."
  value       = aws_iam_role.github_config_plan.arn
}

output "github_config_apply_role_arn" {
  description = "OIDC role scoped to GitHub configuration state; GitHub access comes from a separate App token."
  value       = aws_iam_role.github_config_apply.arn
}
