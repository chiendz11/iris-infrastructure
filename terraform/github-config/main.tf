locals {
  foundation = data.terraform_remote_state.foundation.outputs
  platform   = var.manage_application_config ? data.terraform_remote_state.platform[0].outputs : null

  infrastructure_variables = {
    AWS_REGION                      = var.aws_region
    TF_STATE_BUCKET                 = local.foundation.state_bucket
    TF_STATE_KMS_KEY_ARN            = local.foundation.state_kms_key_arn
    TERRAFORM_PLAN_ROLE_ARN         = local.foundation.terraform_plan_role_arn
    TERRAFORM_APPLY_ROLE_ARN        = local.foundation.terraform_apply_role_arn
    TF_GOVERNANCE_PLAN_ROLE_ARN     = local.foundation.github_governance_plan_role_arn
    TF_GOVERNANCE_APPLY_ROLE_ARN    = local.foundation.github_governance_apply_role_arn
    TF_GITHUB_CONFIG_PLAN_ROLE_ARN  = local.foundation.github_config_plan_role_arn
    TF_GITHUB_CONFIG_APPLY_ROLE_ARN = local.foundation.github_config_apply_role_arn
    ENABLE_PUBLIC_DOMAIN            = tostring(var.enable_public_domain)
    PUBLIC_DOMAIN_NAME              = var.public_domain_name
    ADMIN_ROLE_ARNS_JSON            = jsonencode(var.admin_role_arns)
  }

  application_environment_variables = var.manage_application_config ? {
    iris-data-pipeline = {
      AWS_REGION              = var.aws_region
      AWS_DEPLOY_ROLE_ARN     = local.platform.github_actions_role_arn
      TRAINING_ECR_REPOSITORY = local.platform.ecr_repository_names.training
      DVC_BUCKET              = local.platform.dvc_bucket
    }
    iris-model-registry = {
      AWS_REGION            = var.aws_region
      AWS_DEPLOY_ROLE_ARN   = local.platform.github_actions_role_arn
      MLFLOW_ECR_REPOSITORY = local.platform.ecr_repository_names.mlflow
      GITOPS_REPOSITORY     = var.gitops_repository
      GITOPS_APP_CLIENT_ID  = var.gitops_app_client_id
    }
    iris-inference-service = {
      AWS_REGION               = var.aws_region
      AWS_DEPLOY_ROLE_ARN      = local.platform.github_actions_role_arn
      INFERENCE_ECR_REPOSITORY = local.platform.ecr_repository_names.inference
      GITOPS_REPOSITORY        = var.gitops_repository
      GITOPS_APP_CLIENT_ID     = var.gitops_app_client_id
    }
  } : {}

  gitops_repository_name = element(split("/", var.gitops_repository), 1)
  gitops_repository_variables = var.manage_application_config ? {
    AWS_REGION                      = var.aws_region
    DISPATCHER_ECR_REPOSITORY       = local.platform.ecr_repository_names.dispatcher
    DISPATCHER_PUBLISH_AWS_ROLE_ARN = local.platform.github_dispatcher_publish_role_arn
    MODEL_PROMOTION_AWS_ROLE_ARN    = local.platform.github_gitops_promotion_role_arn
    MODEL_PROMOTION_SECRET_ARN      = local.platform.model_promotion_github_app_secret_arn
  } : {}

  flattened_application_variables = var.manage_application_config ? merge([
    for repository, variables in local.application_environment_variables : {
      for name, value in variables : "${repository}:${name}" => {
        repository = repository
        name       = name
        value      = value
      }
    }
  ]...) : {}
}

check "foundation_backend_identity" {
  assert {
    condition = (
      var.state_bucket_name == local.foundation.state_bucket &&
      var.state_kms_key_arn == local.foundation.state_kms_key_arn
    )
    error_message = "Backend bucket/KMS inputs must match the authoritative foundation outputs."
  }
}

check "application_environment_coverage" {
  assert {
    condition = !var.manage_application_config || length(setsubtract(
      toset(keys(local.application_environment_variables)),
      var.application_repositories,
    )) == 0
    error_message = "Every repository receiving application variables must have a managed prod Environment."
  }
}

data "github_user" "production_reviewer" {
  for_each = var.manage_application_config ? var.production_reviewer_usernames : toset([])
  username = each.value
}

# The infrastructure repository's prod Environment is intentionally excluded.
# It is the root-of-trust gate that releases credentials capable of changing
# this very configuration and therefore remains an out-of-band owner control.
resource "github_repository_environment" "application_prod" {
  for_each = var.manage_application_config ? var.application_repositories : toset([])

  repository          = each.value
  environment         = var.production_environment
  can_admins_bypass   = false
  prevent_self_review = true

  reviewers {
    users = [
      for reviewer in data.github_user.production_reviewer : tonumber(reviewer.id)
    ]
  }

  deployment_branch_policy {
    protected_branches     = true
    custom_branch_policies = false
  }

  lifecycle {
    prevent_destroy = true
  }
}

# Repository scope is used by credential-free PR plans. Environment scope gives
# the protected apply jobs the same values only after prod approval.
resource "github_actions_variable" "infrastructure" {
  for_each = local.infrastructure_variables

  repository    = var.infrastructure_repository
  variable_name = each.key
  value         = each.value
}

resource "github_actions_environment_variable" "infrastructure_prod" {
  for_each = local.infrastructure_variables

  repository    = var.infrastructure_repository
  environment   = var.production_environment
  variable_name = each.key
  value         = each.value
}

resource "github_actions_environment_variable" "application_prod" {
  for_each = local.flattened_application_variables

  repository    = each.value.repository
  environment   = github_repository_environment.application_prod[each.value.repository].environment
  variable_name = each.value.name
  value         = each.value.value
}

resource "github_actions_variable" "gitops_model_promotion" {
  for_each = local.gitops_repository_variables

  repository    = local.gitops_repository_name
  variable_name = each.key
  value         = each.value
}
