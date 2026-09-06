#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 3 ]]; then
  echo "usage: $0 <public-domain> <admin-role-arn-or-empty> <production-reviewer-usernames-json>" >&2
  echo "example: $0 example.com '' '[\"mentor-login\"]'" >&2
  exit 2
fi

PUBLIC_DOMAIN=$1
ADMIN_ROLE_ARN=${2:-}
PRODUCTION_REVIEWERS_JSON=$3
REPOSITORY=${GITHUB_REPOSITORY:-chiendz11/iris-infrastructure}

echo "DAY-0 ONLY: this script seeds the infrastructure root of trust."
echo "After terraform/github-config is adopted, Terraform owns non-secret GitHub variables."

jq -e --arg owner "${REPOSITORY%%/*}" '
  type == "array" and length > 0 and length <= 6 and
  all(.[];
    type == "string" and
    test("^[A-Za-z0-9](?:[A-Za-z0-9-]{0,37}[A-Za-z0-9])?$") and
    (ascii_downcase != ($owner | ascii_downcase))
  )
' <<<"${PRODUCTION_REVIEWERS_JSON}" >/dev/null || {
  echo "production-reviewer-usernames-json must contain 1-6 reviewers other than the owner." >&2
  exit 1
}

REVIEWER_OBJECTS='[]'
while IFS= read -r reviewer; do
  for managed_repository in \
    iris-infrastructure \
    iris-gitops \
    iris-data-pipeline \
    iris-model-registry \
    iris-inference-service; do
    gh api \
      "repos/${REPOSITORY%%/*}/${managed_repository}/collaborators/${reviewer}/permission" \
      --jq .permission >/dev/null || {
      echo "${reviewer} must be a collaborator on ${managed_repository}." >&2
      exit 1
    }
  done
  REVIEWER_ID=$(gh api "users/${reviewer}" --jq .id)
  REVIEWER_OBJECTS=$(jq -c \
    --argjson id "${REVIEWER_ID}" \
    '. + [{type: "User", id: $id}]' <<<"${REVIEWER_OBJECTS}")
done < <(jq -r '.[]' <<<"${PRODUCTION_REVIEWERS_JSON}")

jq -n \
  --argjson reviewers "${REVIEWER_OBJECTS}" \
  '{
    wait_timer: 0,
    prevent_self_review: true,
    can_admins_bypass: false,
    reviewers: $reviewers,
    deployment_branch_policy: {
      protected_branches: true,
      custom_branch_policies: false
    }
  }' | gh api \
    --method PUT \
    "repos/${REPOSITORY}/environments/prod" \
    --input - >/dev/null
echo "Configured the out-of-band infrastructure prod trust gate."

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

set_variable() {
  local name=$1
  local value=$2

  # Repository scope lets the read-only PR plan run without becoming a prod deployment.
  # Environment scope provides the same reviewed inputs to mutation jobs.
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

set_variable PRODUCTION_REVIEWER_USERNAMES_JSON "$PRODUCTION_REVIEWERS_JSON"

echo "Configured non-secret repository and prod-environment variables for $REPOSITORY."
echo "Use 'pr-gate' (not 'static') as the required infrastructure status check."
echo "Configure the control-plane and model-promoter GitHub Apps described in docs/GITHUB_CONTROL_PLANE.md."
echo "CONFIG_SYNC_APP_PRIVATE_KEY, GOVERNANCE_APP_PRIVATE_KEY and GITOPS_APP_PRIVATE_KEY remain Environment secrets."
echo "The normal lifecycle now uses Terraform; do not rerun this script for day-2 variable updates."
