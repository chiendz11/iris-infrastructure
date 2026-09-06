#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "usage: $0 <enable-public-domain> <domain-name>" >&2
  exit 2
fi

ENABLE_PUBLIC_DOMAIN=$1
DESIRED_DOMAIN=$2

if [[ "${ENABLE_PUBLIC_DOMAIN}" != "true" ]]; then
  echo false
  exit 0
fi

if ! command -v dig >/dev/null 2>&1; then
  echo "dig is required to verify public Route53 delegation." >&2
  exit 1
fi

CURRENT_DOMAIN="$(terraform output -raw domain_name 2>/dev/null || true)"
CURRENT_READY="$(terraform output -raw domain_ready 2>/dev/null || echo false)"
CERTIFICATE_STATE_PRESENT=false
if terraform state list 2>/dev/null | grep -Eq \
  '^aws_(acm_certificate|acm_certificate_validation|route53_record)\.(public|certificate_validation)'; then
  CERTIFICATE_STATE_PRESENT=true
fi
EXPECTED="$({
  terraform output -json route53_name_servers 2>/dev/null || echo '[]'
} | jq -r '.[]' 2>/dev/null | tr '[:upper:]' '[:lower:]' | sed 's/\.$//' | sort -u)"

# No existing zone (or a first apply for a new name) means phase one must only
# create the hosted zone. The registrar cannot be delegated before this.
if [[ "${CURRENT_DOMAIN}" != "${DESIRED_DOMAIN}" || -z "${EXPECTED}" ]]; then
  echo false
  exit 0
fi

ACTUAL="$(
  dig +short NS "${DESIRED_DOMAIN}" |
    tr '[:upper:]' '[:lower:]' |
    sed 's/\.$//' |
    sort -u
)"

if [[ -n "${ACTUAL}" ]] && diff -q \
  <(printf '%s\n' "${EXPECTED}") \
  <(printf '%s\n' "${ACTUAL}") >/dev/null; then
  echo true
  exit 0
fi

# Once a certificate is present, silently switching the input back to false
# would make Terraform plan its deletion. Fail closed if public DNS drifts.
if [[ "${CURRENT_READY}" == "true" || "${CERTIFICATE_STATE_PRESENT}" == "true" ]]; then
  echo "Public NS for ${DESIRED_DOMAIN} no longer matches the Route53 delegation set." >&2
  echo "Refusing to plan with domain_delegated=false because ACM state already exists." >&2
  exit 1
fi

echo false
