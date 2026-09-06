# Adopt configuration that was created by the legacy bootstrap scripts. These
# import blocks are safe to retain after the first apply.
import {
  to = github_actions_environment_variable.infrastructure_prod["AWS_REGION"]
  id = "iris-infrastructure:prod:AWS_REGION"
}

locals {
  existing_application_environments = var.manage_application_config ? var.application_repositories : toset([])

  existing_application_variables = var.manage_application_config ? {
    "iris-data-pipeline:AWS_REGION"                   = "iris-data-pipeline:prod:AWS_REGION"
    "iris-data-pipeline:TRAINING_ECR_REPOSITORY"      = "iris-data-pipeline:prod:TRAINING_ECR_REPOSITORY"
    "iris-model-registry:AWS_REGION"                  = "iris-model-registry:prod:AWS_REGION"
    "iris-model-registry:GITOPS_REPOSITORY"           = "iris-model-registry:prod:GITOPS_REPOSITORY"
    "iris-model-registry:MLFLOW_ECR_REPOSITORY"       = "iris-model-registry:prod:MLFLOW_ECR_REPOSITORY"
    "iris-inference-service:AWS_REGION"               = "iris-inference-service:prod:AWS_REGION"
    "iris-inference-service:GITOPS_REPOSITORY"        = "iris-inference-service:prod:GITOPS_REPOSITORY"
    "iris-inference-service:INFERENCE_ECR_REPOSITORY" = "iris-inference-service:prod:INFERENCE_ECR_REPOSITORY"
  } : {}
}

import {
  for_each = local.existing_application_environments
  to       = github_repository_environment.application_prod[each.value]
  id       = "${each.value}:${var.production_environment}"
}

import {
  for_each = local.existing_application_variables
  to       = github_actions_environment_variable.application_prod[each.key]
  id       = each.value
}
