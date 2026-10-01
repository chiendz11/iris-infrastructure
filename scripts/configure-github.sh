#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "usage: $0 <public-domain> <admin-role-arn-or-empty>" >&2
  echo "Solo profile: the personal repository owner is the deployment approver. Existing setups should use configure-solo-environment.sh." >&2
  exit 2
fi

PUBLIC_DOMAIN=$1
ADMIN_ROLE_ARN=${2:-}
REPOSITORY=${GITHUB_REPOSITORY:-chiendz11/iris-infrastructure}

echo "DAY-0 ONLY: this script seeds the infrastructure root of trust."
echo "After terraform/github-config is adopted, Terraform owns non-secret GitHub variables."

STATE_BUCKET=$(terraform -chdir=terraform/bootstrap output -raw state_bucket)
PLAN_ROLE_ARN=$(terraform -chdir=terraform/bootstrap output -raw terraform_plan_role_arn)
APPLY_ROLE_ARN=$(terraform -chdir=terraform/bootstrap output -raw terraform_apply_role_arn)
GOVERNANCE_PLAN_ROLE_ARN=$(terraform -chdir=terraform/bootstrap output -raw github_governance_plan_role_arn)
GOVERNANCE_APPLY_ROLE_ARN=$(terraform -chdir=terraform/bootstrap output -raw github_governance_apply_role_arn)
GITHUB_CONFIG_PLAN_ROLE_ARN=$(terraform -chdir=terraform/bootstrap output -raw github_config_plan_role_arn)
GITHUB_CONFIG_APPLY_ROLE_ARN=$(terraform -chdir=terraform/bootstrap output -raw github_config_apply_role_arn)
KMS_KEY_ARN=$(terraform -chdir=terraform/bootstrap output -raw state_kms_key_arn)
ADMIN_ROLE_ARNS='[]'
if [[ -n "$ADMIN_ROLE_ARN" ]]; then
  [[ "${ADMIN_ROLE_ARN}" =~ ^arn:aws:iam::[0-9]{12}:role/[A-Za-z0-9+=,.@_/-]+$ ]] || {
    echo "admin-role-arn must be an IAM role ARN or an empty string." >&2
    exit 1
  }
  ADMIN_ROLE_ARNS=$(printf '["%s"]' "$ADMIN_ROLE_ARN")
fi

bash "$(dirname "${BASH_SOURCE[0]}")/configure-solo-environment.sh"

set_variable() {
  local name=$1
  local value=$2

  # Repository scope lets the read-only PR plan run without becoming a prod deployment.
  # Environment scope provides the same inputs to protected-branch mutation jobs.
  gh variable set "$name" --repo "$REPOSITORY" --body "$value"
  gh variable set "$name" --repo "$REPOSITORY" --env prod --body "$value"
}

set_variable AWS_REGION "ap-southeast-1"
set_variable TF_STATE_BUCKET "$STATE_BUCKET"
set_variable TF_STATE_KMS_KEY_ARN "$KMS_KEY_ARN"
set_variable TERRAFORM_PLAN_ROLE_ARN "$PLAN_ROLE_ARN"
set_variable TERRAFORM_APPLY_ROLE_ARN "$APPLY_ROLE_ARN"
set_variable TF_GOVERNANCE_PLAN_ROLE_ARN "$GOVERNANCE_PLAN_ROLE_ARN"
set_variable TF_GOVERNANCE_APPLY_ROLE_ARN "$GOVERNANCE_APPLY_ROLE_ARN"
set_variable TF_GITHUB_CONFIG_PLAN_ROLE_ARN "$GITHUB_CONFIG_PLAN_ROLE_ARN"
set_variable TF_GITHUB_CONFIG_APPLY_ROLE_ARN "$GITHUB_CONFIG_APPLY_ROLE_ARN"
set_variable ENABLE_PUBLIC_DOMAIN "true"
set_variable PUBLIC_DOMAIN_NAME "$PUBLIC_DOMAIN"
set_variable ADMIN_ROLE_ARNS_JSON "$ADMIN_ROLE_ARNS"

echo "Configured non-secret repository and prod-environment variables for $REPOSITORY."
echo "Use 'pr-gate' (not 'static') as the required infrastructure status check."
echo "Configure the control-plane, component-publisher, platform-publisher and GitOps-automation Apps described in docs/GITHUB_CONTROL_PLANE.md."
echo "All App private keys remain out of Terraform; place each only in the Environment or Secrets Manager container documented there."
echo "Solo profile: no collaborator PR approval; the owner self-approves prod deployments. PR/CI remain required."
echo "The normal lifecycle now uses Terraform; do not rerun this script for day-2 variable updates."
