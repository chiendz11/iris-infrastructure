#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 3 ]]; then
  echo "usage: $0 <state-bucket> <public-domain> <route53-zone-id> [admin-role-arn]" >&2
  exit 2
fi

STATE_BUCKET=$1
PUBLIC_DOMAIN=$2
ROUTE53_ZONE_ID=$3
ADMIN_ROLE_ARN=${4:-}
REPOSITORY=${GITHUB_REPOSITORY:-chiendz11/iris-infrastructure}

PLAN_ROLE_ARN=$(terraform -chdir=terraform/bootstrap output -raw terraform_plan_role_arn)
APPLY_ROLE_ARN=$(terraform -chdir=terraform/bootstrap output -raw terraform_apply_role_arn)
KMS_KEY_ARN=$(terraform -chdir=terraform/bootstrap output -raw state_kms_key_arn)
ADMIN_ROLE_ARNS='[]'
if [[ -n "$ADMIN_ROLE_ARN" ]]; then
  ADMIN_ROLE_ARNS=$(printf '["%s"]' "$ADMIN_ROLE_ARN")
fi

gh variable set AWS_REGION --repo "$REPOSITORY" --env prod --body "ap-southeast-1"
gh variable set TF_STATE_BUCKET --repo "$REPOSITORY" --env prod --body "$STATE_BUCKET"
gh variable set TF_STATE_KMS_KEY_ARN --repo "$REPOSITORY" --env prod --body "$KMS_KEY_ARN"
gh variable set TERRAFORM_PLAN_ROLE_ARN --repo "$REPOSITORY" --env prod --body "$PLAN_ROLE_ARN"
gh variable set TERRAFORM_APPLY_ROLE_ARN --repo "$REPOSITORY" --env prod --body "$APPLY_ROLE_ARN"
gh variable set ENABLE_PUBLIC_DOMAIN --repo "$REPOSITORY" --env prod --body "true"
gh variable set PUBLIC_DOMAIN_NAME --repo "$REPOSITORY" --env prod --body "$PUBLIC_DOMAIN"
gh variable set ROUTE53_ZONE_ID --repo "$REPOSITORY" --env prod --body "$ROUTE53_ZONE_ID"
gh variable set ADMIN_ROLE_ARNS_JSON --repo "$REPOSITORY" --env prod --body "$ADMIN_ROLE_ARNS"

echo "Configured non-secret GitHub Actions variables for $REPOSITORY."
echo "Add GITOPS_TOKEN as a repository secret, or replace it with a GitHub App token."
