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

# Read the JSON object once. A missing named output can print a human-readable
# warning to stdout; appending [] does not make that stream valid JSON.
# Empty state is normal on first deploy, but backend/authentication failures are not.
if ! OUTPUTS="$(terraform output -json)"; then
  echo "Cannot read domain outputs; refusing to assume an undeployed domain." >&2
  exit 1
fi
if ! jq -e '
  type == "object" and
  (.domain_name.value == null or (.domain_name.value | type == "string")) and
  (.domain_ready.value == null or (.domain_ready.value | type == "boolean")) and
  (.route53_name_servers.value == null or (.route53_name_servers.value |
    type == "array" and all(.[]; type == "string" and length > 0)))
' <<<"${OUTPUTS}" >/dev/null; then
  echo "Domain outputs have an invalid JSON shape; refusing to guess DNS phase." >&2
  exit 1
fi
CURRENT_DOMAIN="$(jq -r '.domain_name.value // ""' <<<"${OUTPUTS}")"
CURRENT_DOMAIN="${CURRENT_DOMAIN%.}"
CURRENT_DOMAIN="${CURRENT_DOMAIN,,}"
DESIRED_DOMAIN="${DESIRED_DOMAIN%.}"
DESIRED_DOMAIN="${DESIRED_DOMAIN,,}"
CURRENT_READY="$(jq -r '.domain_ready.value // false' <<<"${OUTPUTS}")"
EXPECTED="$(jq -r '(.route53_name_servers.value // [])[]' <<<"${OUTPUTS}" |
  tr '[:upper:]' '[:lower:]' | sed 's/\.$//' | sort -u)"

if ! STATE_RESOURCES="$(terraform state list -no-color 2>&1)"; then
  # Only this explicit absent-state diagnostic is safe during initial bootstrap.
  if [[ "$(jq 'length' <<<"${OUTPUTS}")" == 0 &&
        "${STATE_RESOURCES}" == *'No state file was found!'* ]]; then
    STATE_RESOURCES=""
  else
    printf '%s\n' "${STATE_RESOURCES}" >&2
    echo "Cannot inspect domain resources; refusing to guess certificate state." >&2
    exit 1
  fi
fi
CERTIFICATE_STATE_PRESENT=false
if grep -Eq \
  '^aws_(acm_certificate|acm_certificate_validation|route53_record)\.(public|certificate_validation)' \
  <<<"${STATE_RESOURCES}"; then
  CERTIFICATE_STATE_PRESENT=true
fi

# No existing zone (or a first apply for a new name) means phase one must only
# create the hosted zone. The registrar cannot be delegated before this.
if [[ "${CURRENT_DOMAIN}" != "${DESIRED_DOMAIN}" || -z "${EXPECTED}" ]]; then
  if [[ "${CURRENT_READY}" == true || "${CERTIFICATE_STATE_PRESENT}" == true ]]; then
    echo "Existing certificate state has missing or mismatched domain outputs; refusing domain_delegated=false." >&2
    exit 1
  fi
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
