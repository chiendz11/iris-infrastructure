#!/usr/bin/env bash
set -euo pipefail

if (( $# != 0 )); then
  echo "usage: $0 (target: GITHUB_REPOSITORY or chiendz11/iris-infrastructure, Environment prod only)" >&2
  exit 2
fi

REPOSITORY=${GITHUB_REPOSITORY:-chiendz11/iris-infrastructure}
[[ "${REPOSITORY}" =~ ^[A-Za-z0-9][A-Za-z0-9-]*/iris-infrastructure$ ]] || {
  echo "Only the infrastructure repository's out-of-band prod Environment is in scope." >&2
  exit 2
}

for command in gh jq; do
  command -v "$command" >/dev/null || { echo "$command is required." >&2; exit 1; }
done

# Resolve the personal repository owner, not the workflow actor (which may be a bot).
OWNER=${REPOSITORY%%/*}
APPROVER_ID="$(gh api "users/${OWNER}" | jq -er --arg owner "$OWNER" '
  select(.type == "User" and ((.login | ascii_downcase) == ($owner | ascii_downcase)))
  | .id | select(type == "number" and . > 0 and . == floor)
')" || {
  echo "Could not resolve a human owner for self-approval; no Environment was changed." >&2
  exit 1
}

# Explicit operator action, never invoked by CI. Do not delete/recreate the
# Environment: PUT updates protection without replacing variables/secrets.
# App Environments belong to terraform/github-config, not to this script.
jq -n --argjson approver_id "$APPROVER_ID" '{
  wait_timer: 0,
  prevent_self_review: false,
  can_admins_bypass: false,
  reviewers: [{type: "User", id: $approver_id}],
  deployment_branch_policy: {
    protected_branches: true,
    custom_branch_policies: false
  }
}' | gh api --method PUT "repos/${REPOSITORY}/environments/prod" --input - >/dev/null

echo "Configured ${REPOSITORY}/prod: ${OWNER} must approve deployments and may approve their own runs."
echo "No variables, secrets or rulesets were changed. App Environments remain Terraform-owned."
