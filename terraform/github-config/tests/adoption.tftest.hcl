# All GitHub reads/writes and AWS remote-state reads are mocked. These tests
# must never use operator credentials or an actual GitHub/AWS account.
mock_provider "github" {
  mock_data "github_repository_environments" {
    defaults = { environments = [] }
  }
  mock_data "github_actions_variables" {
    defaults = { variables = [] }
  }
  mock_data "github_actions_environment_variables" {
    defaults = { variables = [] }
  }
  mock_data "github_user" {
    defaults = { id = "12345" }
  }
}

variables {
  state_bucket_name                      = "test-state-bucket"
  state_kms_key_arn                      = "arn:aws:kms:ap-southeast-1:123456789012:key/12345678-1234-4234-8234-123456789abc"
  manage_application_config              = true
  inference_publisher_app_client_id      = "inference-client"
  model_registry_publisher_app_client_id = "registry-client"
  platform_contract_publisher_actor      = "platform-publisher[bot]"
  inference_publisher_actor              = "inference-publisher[bot]"
  model_registry_publisher_actor         = "registry-publisher[bot]"
  model_release_publisher_actor          = "model-publisher[bot]"
}

override_data {
  target = data.terraform_remote_state.foundation
  values = {
    outputs = {
      state_bucket                     = "test-state-bucket"
      state_kms_key_arn                = "arn:aws:kms:ap-southeast-1:123456789012:key/12345678-1234-4234-8234-123456789abc"
      terraform_plan_role_arn          = "plan-role"
      terraform_apply_role_arn         = "apply-role"
      github_governance_plan_role_arn  = "governance-plan"
      github_governance_apply_role_arn = "governance-apply"
      github_config_plan_role_arn      = "config-plan"
      github_config_apply_role_arn     = "config-apply"
    }
  }
}

override_data {
  target = data.terraform_remote_state.platform
  values = {
    outputs = {
      github_application_publisher_role_arns     = { training = "train-role", mlflow = "mlflow-role", inference = "inference-role" }
      ecr_repository_names                       = { training = "iris-training", mlflow = "iris-mlflow", inference = "iris-inference", dispatcher = "iris-dispatcher" }
      dvc_bucket                                 = "test-dvc"
      github_release_automation_publish_role_arn = "automation-publish-role"
      github_gitops_automation_role_arn          = "automation-role"
      gitops_automation_github_app_secret_arn    = "automation-secret-arn"
    }
  }
}

run "fresh_app_repositories_create_not_import" {
  command = plan
  assert {
    condition     = length(local.existing_application_environments) == 0 && length(local.existing_application_variables) == 0
    error_message = "Fresh app repositories must have no import targets."
  }
  assert {
    condition     = length(github_repository_environment.application_prod) == 3 && length(github_actions_environment_variable.application_prod) > 0
    error_message = "Resource declarations must still create app prod Environments and variables."
  }
  assert {
    condition     = toset(keys(data.github_actions_environment_variables.existing)) == toset(["iris-infrastructure"])
    error_message = "Do not query variables under missing Environments."
  }
}

override_data {
  target = data.github_repository_environments.existing["iris-infrastructure"]
  values = { environments = [{ name = "prod", node_id = "prod-infra" }] }
}

run "missing_root_of_trust_fails_closed" {
  command = plan
  override_data {
    target = data.github_repository_environments.existing["iris-infrastructure"]
    values = { environments = [] }
  }
  expect_failures = [data.github_repository_environments.existing["iris-infrastructure"]]
}

run "mixed_existing_configuration_adopts_only_owned_names" {
  command = plan
  override_resource {
    target = github_repository_environment.application_prod["iris-inference-service"]
    values = { id = "iris-inference-service:prod", repository = "iris-inference-service", environment = "prod" }
  }
  override_resource {
    target = github_actions_environment_variable.application_prod["iris-inference-service:AWS_REGION"]
    values = { id = "iris-inference-service:prod:AWS_REGION", repository = "iris-inference-service", environment = "prod", variable_name = "AWS_REGION", value = "old-region" }
  }
  override_resource {
    target = github_actions_environment_variable.infrastructure_prod["TF_STATE_BUCKET"]
    values = { id = "iris-infrastructure:prod:TF_STATE_BUCKET", repository = "iris-infrastructure", environment = "prod", variable_name = "TF_STATE_BUCKET", value = "old-bucket" }
  }
  override_resource {
    target = github_actions_variable.infrastructure["AWS_REGION"]
    values = { id = "iris-infrastructure:AWS_REGION", repository = "iris-infrastructure", variable_name = "AWS_REGION", value = "old-region" }
  }
  override_resource {
    target = github_actions_variable.gitops_automation["GITOPS_AUTOMATION_SECRET_ARN"]
    values = { id = "iris-gitops:GITOPS_AUTOMATION_SECRET_ARN", repository = "iris-gitops", variable_name = "GITOPS_AUTOMATION_SECRET_ARN", value = "old-arn" }
  }
  override_data {
    target = data.github_repository_environments.existing["iris-inference-service"]
    values = { environments = [{ name = "prod", node_id = "prod-inference" }] }
  }
  override_data {
    target = data.github_repository_environments.existing["iris-infrastructure"]
    values = { environments = [{ name = "prod", node_id = "prod-infra" }] }
  }
  override_data {
    target = data.github_actions_environment_variables.existing["iris-inference-service"]
    values = { variables = [{ name = "AWS_REGION", value = "old-region" }, { name = "UNMANAGED", value = "leave-alone" }] }
  }
  override_data {
    target = data.github_actions_environment_variables.existing["iris-infrastructure"]
    values = { variables = [{ name = "TF_STATE_BUCKET", value = "old-bucket" }] }
  }
  override_data {
    target = data.github_actions_variables.existing["iris-infrastructure"]
    values = { variables = [{ name = "AWS_REGION", value = "old-region" }, { name = "UNMANAGED", value = "leave-alone" }] }
  }
  override_data {
    target = data.github_actions_variables.existing["iris-gitops"]
    values = { variables = [{ name = "GITOPS_AUTOMATION_SECRET_ARN", value = "old-arn" }] }
  }
  assert {
    condition     = local.existing_application_environments == toset(["iris-inference-service"])
    error_message = "Adopt only the app Environment that exists; never adopt the infra trust gate."
  }
  assert {
    condition     = toset(keys(local.existing_application_variables)) == toset(["iris-inference-service:AWS_REGION"])
    error_message = "Import only managed app variable names; leave unrelated variables untouched."
  }
  assert {
    condition     = local.existing_infrastructure_variables == toset(["AWS_REGION"]) && local.existing_infrastructure_environment_variables == toset(["TF_STATE_BUCKET"])
    error_message = "Adopt all matching day-zero variables, not only hardcoded AWS_REGION."
  }
  assert {
    condition     = local.existing_gitops_variables == toset(["GITOPS_AUTOMATION_SECRET_ARN"])
    error_message = "Existing GitOps receiver variables must also be adopted."
  }
}

run "existing_environment_with_no_variables" {
  command = plan
  override_resource {
    target = github_repository_environment.application_prod["iris-model-registry"]
    values = { id = "iris-model-registry:prod", repository = "iris-model-registry", environment = "prod" }
  }
  override_data {
    target = data.github_repository_environments.existing["iris-model-registry"]
    values = { environments = [{ name = "prod", node_id = "prod-registry" }] }
  }
  assert {
    condition     = local.existing_application_environments == toset(["iris-model-registry"]) && length(local.existing_application_variables) == 0
    error_message = "Adopt Environment and create missing variables independently."
  }
}

run "foundation_only_does_not_query_apps" {
  command = plan
  variables { manage_application_config = false }
  assert {
    condition     = local.discovery_repositories == toset(["iris-infrastructure"]) && length(github_repository_environment.application_prod) == 0
    error_message = "No app discovery or resource creation before platform outputs exist."
  }
}

run "pr_plans_do_not_discover_or_import" {
  command = plan
  variables { discover_existing_configuration = false }
  assert {
    condition     = length(data.github_repository_environments.existing) == 0 && length(data.github_actions_variables.existing) == 0 && length(data.github_actions_environment_variables.existing) == 0
    error_message = "PR plans must not request privileged GitHub configuration reads."
  }
  assert {
    condition     = length(local.existing_application_environments) == 0 && length(local.existing_infrastructure_variables) == 0 && length(local.existing_gitops_variables) == 0
    error_message = "PR plans must not import live objects."
  }
}
