#!/usr/bin/env bash
set -euo pipefail

if (( $# != 2 )); then
  echo "usage: $0 <domain> <expected-nameservers-json>" >&2
  exit 2
fi
DOMAIN=$1
MAX_ATTEMPTS=${DNS_MAX_ATTEMPTS:-40}
RETRY_SECONDS=${DNS_RETRY_SECONDS:-30}
[[ "$DOMAIN" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*\.[A-Za-z]{2,}\.?$ ]] || {
  echo "Invalid public domain." >&2; exit 2;
}
[[ "$MAX_ATTEMPTS" =~ ^[1-9][0-9]*$ && "$RETRY_SECONDS" =~ ^[1-9][0-9]*$ ]] || {
  echo "DNS_MAX_ATTEMPTS and DNS_RETRY_SECONDS must be positive integers." >&2; exit 2;
}
(( MAX_ATTEMPTS <= 120 && RETRY_SECONDS <= 60 )) || {
  echo "DNS polling is bounded to 120 attempts and at most 60 seconds between attempts." >&2; exit 2;
}
for command in dig jq; do
  command -v "$command" >/dev/null || { echo "$command is required." >&2; exit 1; }
done
jq -e 'type == "array" and length > 0 and all(.[]; type == "string" and test("^[A-Za-z0-9][A-Za-z0-9.-]*\\.[A-Za-z]{2,}\\.?$"))' \
  <<<"$2" >/dev/null || { echo "Expected nameservers must be a nonempty JSON array of DNS names." >&2; exit 2; }
EXPECTED=$(jq -r '.[] | ascii_downcase | rtrimstr(".")' <<<"$2" | sort -u)

for (( attempt=1; attempt<=MAX_ATTEMPTS; attempt++ )); do
  # DNS errors/NXDOMAIN are not approval: retry, then fail closed on timeout.
  ANSWER=$(dig +time=5 +tries=1 +short NS "$DOMAIN" 2>/dev/null || true)
  ACTUAL=$(printf '%s\n' "$ANSWER" | tr '[:upper:]' '[:lower:]' | sed '/^$/d; s/\.$//' | sort -u)
  if [[ -n "$ACTUAL" && "$ACTUAL" == "$EXPECTED" ]]; then
    echo "Public NS matches Route53 for ${DOMAIN}; certificate reconciliation may continue."
    exit 0
  fi
  echo "Waiting for public NS delegation of ${DOMAIN} (${attempt}/${MAX_ATTEMPTS})."
  if (( attempt < MAX_ATTEMPTS )); then
    sleep "$RETRY_SECONDS"
  fi
done

echo "DNS delegation is not ready. Set the registrar NS from the job summary, then rerun terraform-domain-certificate.yml and approve prod." >&2
echo "No certificate/platform handoff was authorized by this check." >&2
exit 1
