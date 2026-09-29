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
    GITOPS_REPOSITORY               = var.gitops_repository
  }

  application_environment_variables = var.manage_application_config ? {
    iris-data-pipeline = {
      AWS_REGION              = var.aws_region
      AWS_DEPLOY_ROLE_ARN     = local.platform.github_application_publisher_role_arns.training
      TRAINING_ECR_REPOSITORY = local.platform.ecr_repository_names.training
      DVC_BUCKET              = local.platform.dvc_bucket
    }
    iris-model-registry = {
      AWS_REGION                     = var.aws_region
      AWS_DEPLOY_ROLE_ARN            = local.platform.github_application_publisher_role_arns.mlflow
      MLFLOW_ECR_REPOSITORY          = local.platform.ecr_repository_names.mlflow
      GITOPS_REPOSITORY              = var.gitops_repository
      INTENT_PUBLISHER_APP_CLIENT_ID = var.model_registry_publisher_app_client_id
    }
    iris-inference-service = {
      AWS_REGION                     = var.aws_region
      AWS_DEPLOY_ROLE_ARN            = local.platform.github_application_publisher_role_arns.inference
      INFERENCE_ECR_REPOSITORY       = local.platform.ecr_repository_names.inference
      GITOPS_REPOSITORY              = var.gitops_repository
      INTENT_PUBLISHER_APP_CLIENT_ID = var.inference_publisher_app_client_id
    }
  } : {}

  gitops_repository_name = element(split("/", var.gitops_repository), 1)
  gitops_repository_variables = var.manage_application_config ? {
    AWS_REGION                              = var.aws_region
    RELEASE_AUTOMATION_ECR_REPOSITORY       = local.platform.ecr_repository_names.dispatcher
    RELEASE_AUTOMATION_PUBLISH_AWS_ROLE_ARN = local.platform.github_release_automation_publish_role_arn
    GITOPS_AUTOMATION_AWS_ROLE_ARN          = local.platform.github_gitops_automation_role_arn
    GITOPS_AUTOMATION_SECRET_ARN            = local.platform.gitops_automation_github_app_secret_arn
    PLATFORM_RECONCILE_ALLOWED_ACTOR        = var.platform_contract_publisher_actor
    INFERENCE_RELEASE_ALLOWED_ACTOR         = var.inference_publisher_actor
    MODEL_REGISTRY_RELEASE_ALLOWED_ACTOR    = var.model_registry_publisher_actor
    MODEL_RELEASE_ALLOWED_ACTOR             = var.model_release_publisher_actor
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

check "publisher_identities_are_distinct" {
  assert {
    condition = !var.manage_application_config || length(toset([
      var.platform_contract_publisher_actor,
      var.inference_publisher_actor,
      var.model_registry_publisher_actor,
      var.model_release_publisher_actor,
    ])) == 4
    error_message = "Platform, inference, model-registry and model-release publisher Apps must use distinct bot identities."
  }
}

data "github_user" "deployment_approver" {
  count    = var.manage_application_config ? 1 : 0
  username = var.github_owner
}

# The infrastructure repository's prod Environment is intentionally excluded.
# It is the root-of-trust gate that releases credentials capable of changing
# this very configuration and therefore remains an out-of-band owner control.
resource "github_repository_environment" "application_prod" {
  for_each = var.manage_application_config ? var.application_repositories : toset([])

  repository        = each.value
  environment       = var.production_environment
  can_admins_bypass = false
  # Same human may initiate and approve a deployment; PR approvals remain zero.
  prevent_self_review = false

  reviewers {
    users = [tonumber(data.github_user.deployment_approver[0].id)]
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
# the protected-branch apply jobs the same values after owner approval in prod.
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

resource "github_actions_variable" "gitops_automation" {
  for_each = local.gitops_repository_variables

  repository    = local.gitops_repository_name
  variable_name = each.key
  value         = each.value
}
