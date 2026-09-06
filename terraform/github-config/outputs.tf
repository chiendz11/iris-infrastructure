output "managed_infrastructure_repository_variables" {
  description = "Non-secret infrastructure variables reconciled at repository and prod Environment scope."
  value       = sort(keys(local.infrastructure_variables))
}

output "managed_application_environments" {
  description = "Application production Environments owned by this root."
  value       = sort(keys(github_repository_environment.application_prod))
}

output "managed_application_environment_variables" {
  description = "Non-secret application deployment variables managed from platform outputs."
  value = {
    for repository, variables in local.application_environment_variables :
    repository => sort(keys(variables))
  }
}

output "managed_gitops_repository_variables" {
  description = "Non-secret OIDC/ECR/secret metadata used by GitOps release automation."
  value       = sort(keys(local.gitops_repository_variables))
}
