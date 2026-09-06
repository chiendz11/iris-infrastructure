#!/usr/bin/env bash
set -euo pipefail

if (( $# != 2 )); then
  echo "Usage: $0 <github-app-client-id> </secure/path/model-promoter.pem>" >&2
  exit 2
fi

client_id="$1"
private_key_path="$2"
platform_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../terraform/platform" && pwd)"

test -n "${client_id}" || { echo "GitHub App Client ID is required." >&2; exit 1; }
test -r "${private_key_path}" || { echo "Private key is not readable: ${private_key_path}" >&2; exit 1; }
command -v aws >/dev/null || { echo "aws CLI is required." >&2; exit 1; }
command -v jq >/dev/null || { echo "jq is required." >&2; exit 1; }
command -v terraform >/dev/null || { echo "terraform CLI is required." >&2; exit 1; }

secret_arn="$(terraform -chdir="${platform_dir}" output -raw model_promotion_github_app_secret_arn)"
secret_region="$(cut -d: -f4 <<<"${secret_arn}")"
test -n "${secret_region}" || { echo "Could not derive AWS region from secret ARN." >&2; exit 1; }
payload_file="$(mktemp)"
cleanup() {
  rm -f -- "${payload_file}"
}
trap cleanup EXIT
chmod 600 "${payload_file}"

jq -n \
  --arg client_id "${client_id}" \
  --rawfile private_key "${private_key_path}" \
  '{client_id: $client_id, private_key: $private_key}' > "${payload_file}"

aws secretsmanager put-secret-value \
  --region "${secret_region}" \
  --secret-id "${secret_arn}" \
  --secret-string "file://${payload_file}" \
  --output json >/dev/null

echo "Seeded a new model-promoter credential version in AWS Secrets Manager."
