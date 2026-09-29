#!/usr/bin/env bash
# Read-only: block old approved runs before they obtain privileged credentials.
set -euo pipefail
[[ "${GITHUB_REPOSITORY:-}" == "chiendz11/iris-infrastructure" ]]
[[ "${GITHUB_REF:-}" == refs/heads/main ]]
[[ "${GITHUB_EVENT_NAME:-}" == push || "${GITHUB_EVENT_NAME:-}" == workflow_dispatch ]]
[[ "${GITHUB_SHA:-}" =~ ^[0-9a-f]{40}$ ]]
[[ "$(git rev-parse HEAD)" == "${GITHUB_SHA}" ]]
remote_sha="$(git ls-remote --exit-code origin refs/heads/main | cut -f1)"
if [[ "${remote_sha}" != "${GITHUB_SHA}" ||
      ( -n "${EXPECTED_SHA:-}" && "${EXPECTED_SHA}" != "${GITHUB_SHA}" ) ]]; then
  echo "Stale production execution. Review current main and dispatch production-infra.yml with the needed scope (all if unsure)." >&2
  exit 1
fi
