output "managed_infrastructure_repository_variables" {
  description = "Non-secret infrastructure variables reconciled at repository and prod Environment scope."
  value       = sort(keys(local.infrastructure_variables))
}

output "managed_application_environments" {
  description = "Application production Environments owned by this root."
  value       = sort(keys(github_repository_environment.application_prod))
}

output "application_deployment_approver" {
  description = "Personal GitHub owner required to self-approve app prod deployments; not a PR reviewer requirement."
  value       = var.manage_application_config ? var.github_owner : null
}

output "managed_application_environment_variables" {
  description = "Non-secret application deployment variables managed from platform outputs."
  value = {
    for repository, variables in local.application_environment_variables :
    repository => sort(keys(variables))
  }
}

output "managed_gitops_repository_variables" {
  description = "Non-secret OIDC/ECR/secret metadata used by trusted GitOps renderers."
  value       = sort(keys(local.gitops_repository_variables))
}
