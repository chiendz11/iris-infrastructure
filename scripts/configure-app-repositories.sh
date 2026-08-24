#!/usr/bin/env bash
set -euo pipefail

ENVIRONMENT=${GITHUB_ENVIRONMENT:-prod}
AWS_REGION=${AWS_REGION:-ap-southeast-1}
GITOPS_REPOSITORY=${GITOPS_REPOSITORY:-chiendz11/iris-gitops}

DEPLOY_ROLE_ARN=$(terraform -chdir=terraform/platform output -raw github_actions_role_arn)
DVC_BUCKET=$(terraform -chdir=terraform/platform output -raw dvc_bucket)
ECR_REPOSITORIES=$(terraform -chdir=terraform/platform output -json ecr_repository_names)

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

set_variable chiendz11/iris-inference-service AWS_REGION "$AWS_REGION"
set_variable chiendz11/iris-inference-service AWS_DEPLOY_ROLE_ARN "$DEPLOY_ROLE_ARN"
set_variable chiendz11/iris-inference-service INFERENCE_ECR_REPOSITORY "$(jq -r .inference <<<"$ECR_REPOSITORIES")"
set_variable chiendz11/iris-inference-service GITOPS_REPOSITORY "$GITOPS_REPOSITORY"

echo "Configured application deployment variables in GitHub Environment $ENVIRONMENT."
