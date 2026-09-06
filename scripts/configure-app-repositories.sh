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
GITOPS_APP_CLIENT_ID=${GITOPS_APP_CLIENT_ID:-}

test -n "${GITOPS_APP_CLIENT_ID}" || {
  echo "GITOPS_APP_CLIENT_ID is required for break-glass application configuration." >&2
  exit 1
}

DEPLOY_ROLE_ARN=$(terraform -chdir=terraform/platform output -raw github_actions_role_arn)
DVC_BUCKET=$(terraform -chdir=terraform/platform output -raw dvc_bucket)
ECR_REPOSITORIES=$(terraform -chdir=terraform/platform output -json ecr_repository_names)
DISPATCHER_PUBLISH_ROLE_ARN=$(terraform -chdir=terraform/platform output -raw github_dispatcher_publish_role_arn)
MODEL_PROMOTION_ROLE_ARN=$(terraform -chdir=terraform/platform output -raw github_gitops_promotion_role_arn)
MODEL_PROMOTION_SECRET_ARN=$(terraform -chdir=terraform/platform output -raw model_promotion_github_app_secret_arn)

set_variable() {
  repository=$1
  name=$2
  value=$3
  gh variable set "$name" --repo "$repository" --env "$ENVIRONMENT" --body "$value"
}

set_variable chiendz11/iris-data-pipeline AWS_REGION "$AWS_REGION"
set_variable chiendz11/iris-data-pipeline AWS_DEPLOY_ROLE_ARN "$DEPLOY_ROLE_ARN"
set_variable chiendz11/iris-data-pipeline TRAINING_ECR_REPOSITORY "$(jq -r .training <<<"$ECR_REPOSITORIES")"
set_variable chiendz11/iris-data-pipeline DVC_BUCKET "$DVC_BUCKET"

set_variable chiendz11/iris-model-registry AWS_REGION "$AWS_REGION"
set_variable chiendz11/iris-model-registry AWS_DEPLOY_ROLE_ARN "$DEPLOY_ROLE_ARN"
set_variable chiendz11/iris-model-registry MLFLOW_ECR_REPOSITORY "$(jq -r .mlflow <<<"$ECR_REPOSITORIES")"
set_variable chiendz11/iris-model-registry GITOPS_REPOSITORY "$GITOPS_REPOSITORY"
set_variable chiendz11/iris-model-registry GITOPS_APP_CLIENT_ID "$GITOPS_APP_CLIENT_ID"

set_variable chiendz11/iris-inference-service AWS_REGION "$AWS_REGION"
set_variable chiendz11/iris-inference-service AWS_DEPLOY_ROLE_ARN "$DEPLOY_ROLE_ARN"
set_variable chiendz11/iris-inference-service INFERENCE_ECR_REPOSITORY "$(jq -r .inference <<<"$ECR_REPOSITORIES")"
set_variable chiendz11/iris-inference-service GITOPS_REPOSITORY "$GITOPS_REPOSITORY"
set_variable chiendz11/iris-inference-service GITOPS_APP_CLIENT_ID "$GITOPS_APP_CLIENT_ID"

gh variable set AWS_REGION --repo "$GITOPS_REPOSITORY" --body "$AWS_REGION"
gh variable set DISPATCHER_ECR_REPOSITORY --repo "$GITOPS_REPOSITORY" \
  --body "$(jq -r .dispatcher <<<"$ECR_REPOSITORIES")"
gh variable set DISPATCHER_PUBLISH_AWS_ROLE_ARN --repo "$GITOPS_REPOSITORY" \
  --body "$DISPATCHER_PUBLISH_ROLE_ARN"
gh variable set MODEL_PROMOTION_AWS_ROLE_ARN --repo "$GITOPS_REPOSITORY" \
  --body "$MODEL_PROMOTION_ROLE_ARN"
gh variable set MODEL_PROMOTION_SECRET_ARN --repo "$GITOPS_REPOSITORY" \
  --body "$MODEL_PROMOTION_SECRET_ARN"

echo "Break-glass write completed. Re-run terraform-github-config.yml to restore Terraform ownership."
