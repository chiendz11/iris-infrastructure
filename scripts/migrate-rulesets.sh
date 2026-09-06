#!/usr/bin/env bash
set -euo pipefail

MODE=${1:-verify}
if [[ "${MODE}" != "verify" && "${MODE}" != "--remove-legacy" ]]; then
  echo "usage: $0 [--remove-legacy]" >&2
  exit 2
fi

for command in gh jq; do
  command -v "${command}" >/dev/null 2>&1 || {
    echo "${command} is required." >&2
    exit 1
  }
done

OWNER=${GITHUB_OWNER:-chiendz11}
GITHUB_ACTIONS_INTEGRATION_ID=15368
declare -A REQUIRED_CHECKS=(
  [iris-infrastructure]=pr-gate
  [iris-gitops]=validate
  [iris-data-pipeline]=ci-gate
  [iris-model-registry]=ci-gate
  [iris-inference-service]=ci-gate
)

verify_ruleset() {
  local repository=$1
  local required_check=${REQUIRED_CHECKS[${repository}]}
  local ruleset_id
  local ruleset

  ruleset_id="$(
    gh api "repos/${OWNER}/${repository}/rulesets" --jq \
      '[.[] | select(.name == "protect-main" and .source_type == "Repository")][0].id // empty'
  )"
  test -n "${ruleset_id}" || {
    echo "${repository}: protect-main ruleset was not found." >&2
    return 1
  }

  ruleset="$(gh api "repos/${OWNER}/${repository}/rulesets/${ruleset_id}")"
  jq -e \
    --arg check "${required_check}" \
    --argjson integration_id "${GITHUB_ACTIONS_INTEGRATION_ID}" '
      .enforcement == "active" and
      (.conditions.ref_name.include | index("~DEFAULT_BRANCH") != null) and
      ([.rules[].type] | index("deletion") != null) and
      ([.rules[].type] | index("non_fast_forward") != null) and
      ([.rules[].type] | index("required_linear_history") != null) and
      (any(
        .rules[];
        .type == "pull_request" and
        .parameters.dismiss_stale_reviews_on_push == true and
        .parameters.require_code_owner_review == true and
        .parameters.require_last_push_approval == true and
        .parameters.required_approving_review_count == 1 and
        .parameters.required_review_thread_resolution == true
      )) and
      (any(
        .rules[];
        .type == "required_status_checks" and
        .parameters.strict_required_status_checks_policy == true and
        any(
          .parameters.required_status_checks[];
          .context == $check and .integration_id == $integration_id
        )
      ))
    ' <<<"${ruleset}" >/dev/null || {
      echo "${repository}: protect-main does not match Terraform policy." >&2
      return 1
    }

  echo "${repository}: ruleset ${ruleset_id} is active and matches Terraform policy."
}

verification_failed=0
for repository in "${!REQUIRED_CHECKS[@]}"; do
  if ! verify_ruleset "${repository}"; then
    verification_failed=1
  fi
done

if (( verification_failed != 0 )); then
  echo "Ruleset verification failed; no legacy protection was removed." >&2
  exit 1
fi

if [[ "${MODE}" == "--remove-legacy" ]]; then
  # GitHub layers classic protection and rulesets. These two classic rules were
  # created before Terraform adoption and must be removed once, after verification.
  for repository in iris-infrastructure iris-gitops; do
    if gh api "repos/${OWNER}/${repository}/branches/main/protection" >/dev/null 2>&1; then
      gh api --method DELETE \
        "repos/${OWNER}/${repository}/branches/main/protection" >/dev/null
      echo "${repository}: removed legacy classic branch protection; protect-main remains active."
    else
      echo "${repository}: legacy classic branch protection is already absent."
    fi
  done
fi
