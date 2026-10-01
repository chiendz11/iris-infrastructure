#!/usr/bin/env bash
# Read only the domain stack's public outputs. Terraform check blocks alone can
# emit warnings, so an explicit preflight stops platform when ACM is not ready.
set -euo pipefail
if [[ "${TF_VAR_enable_public_domain:-false}" == false ]]; then
  exit 0
fi
[[ "${TF_VAR_enable_public_domain}" == true ]]
test -n "${PUBLIC_DOMAIN_NAME:-}"
terraform -chdir=terraform/domain init -input=false \
  -backend-config="bucket=${TF_VAR_state_bucket_name}" \
  -backend-config="region=${AWS_REGION}" \
  -backend-config="kms_key_id=${TF_VAR_state_kms_key_arn}"
ready="$(terraform -chdir=terraform/domain output -raw domain_ready)"
domain="$(terraform -chdir=terraform/domain output -raw domain_name)"
domain="${domain%.}"
expected="${PUBLIC_DOMAIN_NAME%.}"
if [[ "${ready}" != true || "${domain,,}" != "${expected,,}" ]]; then
  echo "Domain is not ready or belongs to another domain. Reconcile domain/DNS/certificate before platform." >&2
  exit 1
fi
