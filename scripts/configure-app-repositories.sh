#!/usr/bin/env bash
set -euo pipefail

if [[ "${ALLOW_BREAK_GLASS_GITHUB_CONFIG:-false}" != "true" ]]; then
  cat >&2 <<'EOF'
DEPRECATED: terraform/github-config now owns application GitHub variables.
The terraform-platform workflow dispatches its reconciliation automatically.
For an audited emergency-only write, set ALLOW_BREAK_GLASS_GITHUB_CONFIG=true.
EOF
  exit 2
fi

ENVIRONMENT=${GITHUB_ENVIRONMENT:-prod}
AWS_REGION=${AWS_REGION:-ap-southeast-1}
GITOPS_REPOSITORY=${GITOPS_REPOSITORY:-chiendz11/iris-gitops}
INFERENCE_PUBLISHER_APP_CLIENT_ID=${INFERENCE_PUBLISHER_APP_CLIENT_ID:-}
MODEL_REGISTRY_PUBLISHER_APP_CLIENT_ID=${MODEL_REGISTRY_PUBLISHER_APP_CLIENT_ID:-}
PLATFORM_CONTRACT_PUBLISHER_ACTOR=${PLATFORM_CONTRACT_PUBLISHER_ACTOR:-}
INFERENCE_PUBLISHER_ACTOR=${INFERENCE_PUBLISHER_ACTOR:-}
MODEL_REGISTRY_PUBLISHER_ACTOR=${MODEL_REGISTRY_PUBLISHER_ACTOR:-}
MODEL_RELEASE_PUBLISHER_ACTOR=${MODEL_RELEASE_PUBLISHER_ACTOR:-}

for required_variable in \
  INFERENCE_PUBLISHER_APP_CLIENT_ID \
  MODEL_REGISTRY_PUBLISHER_APP_CLIENT_ID; do
  test -n "${!required_variable}" || {
    echo "${required_variable} is required for break-glass application configuration." >&2
    exit 1
  }
done
for actor_variable in \
  PLATFORM_CONTRACT_PUBLISHER_ACTOR \
  INFERENCE_PUBLISHER_ACTOR \
  MODEL_REGISTRY_PUBLISHER_ACTOR \
  MODEL_RELEASE_PUBLISHER_ACTOR; do
  [[ "${!actor_variable}" == *'[bot]' ]] || {
    echo "${actor_variable} must be the exact dedicated App bot login." >&2
    exit 1
  }
done

PUBLISHER_ROLE_ARNS=$(terraform -chdir=terraform/platform output -json github_application_publisher_role_arns)
DVC_BUCKET=$(terraform -chdir=terraform/platform output -raw dvc_bucket)
ECR_REPOSITORIES=$(terraform -chdir=terraform/platform output -json ecr_repository_names)
RELEASE_AUTOMATION_PUBLISH_ROLE_ARN=$(terraform -chdir=terraform/platform output -raw github_release_automation_publish_role_arn)
GITOPS_AUTOMATION_ROLE_ARN=$(terraform -chdir=terraform/platform output -raw github_gitops_automation_role_arn)
GITOPS_AUTOMATION_SECRET_ARN=$(terraform -chdir=terraform/platform output -raw gitops_automation_github_app_secret_arn)

set_variable() {
  repository=$1
  name=$2
  value=$3
  gh variable set "$name" --repo "$repository" --env "$ENVIRONMENT" --body "$value"
}

set_variable chiendz11/iris-data-pipeline AWS_REGION "$AWS_REGION"
set_variable chiendz11/iris-data-pipeline AWS_DEPLOY_ROLE_ARN "$(jq -r .training <<<"$PUBLISHER_ROLE_ARNS")"
set_variable chiendz11/iris-data-pipeline TRAINING_ECR_REPOSITORY "$(jq -r .training <<<"$ECR_REPOSITORIES")"
set_variable chiendz11/iris-data-pipeline DVC_BUCKET "$DVC_BUCKET"
set_variable chiendz11/iris-model-registry AWS_REGION "$AWS_REGION"
set_variable chiendz11/iris-model-registry AWS_DEPLOY_ROLE_ARN "$(jq -r .mlflow <<<"$PUBLISHER_ROLE_ARNS")"
set_variable chiendz11/iris-model-registry MLFLOW_ECR_REPOSITORY "$(jq -r .mlflow <<<"$ECR_REPOSITORIES")"
set_variable chiendz11/iris-model-registry GITOPS_REPOSITORY "$GITOPS_REPOSITORY"
set_variable chiendz11/iris-model-registry INTENT_PUBLISHER_APP_CLIENT_ID "$MODEL_REGISTRY_PUBLISHER_APP_CLIENT_ID"

set_variable chiendz11/iris-inference-service AWS_REGION "$AWS_REGION"
set_variable chiendz11/iris-inference-service AWS_DEPLOY_ROLE_ARN "$(jq -r .inference <<<"$PUBLISHER_ROLE_ARNS")"
set_variable chiendz11/iris-inference-service INFERENCE_ECR_REPOSITORY "$(jq -r .inference <<<"$ECR_REPOSITORIES")"
set_variable chiendz11/iris-inference-service GITOPS_REPOSITORY "$GITOPS_REPOSITORY"
set_variable chiendz11/iris-inference-service INTENT_PUBLISHER_APP_CLIENT_ID "$INFERENCE_PUBLISHER_APP_CLIENT_ID"

gh variable set AWS_REGION --repo "$GITOPS_REPOSITORY" --body "$AWS_REGION"
gh variable set RELEASE_AUTOMATION_ECR_REPOSITORY --repo "$GITOPS_REPOSITORY" \
  --body "$(jq -r .dispatcher <<<"$ECR_REPOSITORIES")"
gh variable set RELEASE_AUTOMATION_PUBLISH_AWS_ROLE_ARN --repo "$GITOPS_REPOSITORY" \
  --body "$RELEASE_AUTOMATION_PUBLISH_ROLE_ARN"
gh variable set GITOPS_AUTOMATION_AWS_ROLE_ARN --repo "$GITOPS_REPOSITORY" \
  --body "$GITOPS_AUTOMATION_ROLE_ARN"
gh variable set GITOPS_AUTOMATION_SECRET_ARN --repo "$GITOPS_REPOSITORY" \
  --body "$GITOPS_AUTOMATION_SECRET_ARN"
gh variable set PLATFORM_RECONCILE_ALLOWED_ACTOR --repo "$GITOPS_REPOSITORY" \
  --body "$PLATFORM_CONTRACT_PUBLISHER_ACTOR"
gh variable set INFERENCE_RELEASE_ALLOWED_ACTOR --repo "$GITOPS_REPOSITORY" \
  --body "$INFERENCE_PUBLISHER_ACTOR"
gh variable set MODEL_REGISTRY_RELEASE_ALLOWED_ACTOR --repo "$GITOPS_REPOSITORY" \
  --body "$MODEL_REGISTRY_PUBLISHER_ACTOR"
gh variable set MODEL_RELEASE_ALLOWED_ACTOR --repo "$GITOPS_REPOSITORY" \
  --body "$MODEL_RELEASE_PUBLISHER_ACTOR"

echo "Break-glass write completed. Run production-infra.yml with scope=github-config to restore Terraform ownership."
