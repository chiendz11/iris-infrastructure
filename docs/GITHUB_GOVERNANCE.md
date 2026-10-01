# GitHub ruleset lifecycle — solo production capstone

## Ownership

`terraform/github-governance` is the desired-state owner of `protect-main` across all five repos.
Normal lifecycle: PR -> required CI -> operator merges -> owner self-approves `prod` job -> Terraform
plan/guard/apply -> `scripts/migrate-rulesets.sh` verifies the policy. No second human is required.

Rulesets still require a PR, strict CI from GitHub Actions, resolved conversations and linear
history; force-push and branch deletion remain blocked. No permanent bypass actor is added.
`required_approving_review_count=0`, `require_code_owner_review=false`,
`require_last_push_approval=false`. CODEOWNERS remains ownership documentation.
Stale-review dismissal is retained for optional reviews.

| Repository | Required check |
|---|---|
| iris-infrastructure | pr-gate |
| iris-gitops | validate |
| iris-data-pipeline | ci-gate |
| iris-model-registry | ci-gate |
| iris-inference-service | ci-gate |

When renaming checks, emit both old and new names first, update the ruleset, then retire the old
check. A rule requiring a nonexistent check will block a solo operator just like any other author.

## Credentials and state

State stays at `infrastructure/github-governance.tfstate` in the S3/KMS backend.
Dedicated OIDC state roles do not mutate AWS infrastructure. The separate `iris-governance` App
has Administration write on exactly the five repos; its private key stays in
`iris-infrastructure/prod` as `GOVERNANCE_APP_PRIVATE_KEY`, with Client ID variable
`GOVERNANCE_APP_CLIENT_ID`. Terraform receives only the short-lived installation token.
App creation/installation remains manual; see `GITHUB_CONTROL_PLANE.md`.

The Environment remains a protected-branch credential boundary with the owner as required deployment
reviewer and self-review allowed. It is not a two-person approval process. No workflow automatically merges PRs.
Contents/PR-write tokens used by GitOps could technically merge a passing PR under zero-review
policy; human-only merge is an operating convention, not an enforced identity restriction.

## Adopt existing configuration

1. Ensure the required checks exist and pass on relevant PRs.
2. Bootstrap foundation/state/OIDC once, or reuse the existing remote state.
3. Seed root variables/Apps. For a fresh setup use `configure-github.sh <domain> <admin-role-or-empty>`.
4. To enable owner self-approval on an existing infrastructure Environment, the operator runs
   `bash scripts/configure-solo-environment.sh`. This changes only `iris-infrastructure/prod`
   protection, not variables, secrets or rulesets. App Environments are changed by Terraform.
5. Keep `existing_ruleset_ids={}` unless deliberately asserting a migration identity. The native
   Terraform discovery reads repository-owned rulesets, verifies one matching `protect-main`
   branch policy and imports it; repositories without one get a new resource. No hardcoded IDs
   need copying. Duplicate matches, wrong target, pagination and failed reads stop the plan.
6. Merge the governance changes. If old review rules prevent the first solo merge, temporarily
   change only the three review requirements through the owner UI/CLI as an explicitly recorded
   one-time migration. Keep PR/CI/force-push protections. Then apply Terraform to converge to Git.
   Code not yet merged/applied cannot remove an already enforced remote gate.
7. Run `bash scripts/migrate-rulesets.sh` to verify. Governance CI also performs this automatically.
8. Only if the two documented legacy classic protections still exist, inspect them and explicitly
   run `bash scripts/migrate-rulesets.sh --remove-legacy` after verifying the Terraform rulesets.
   This deletes classic protections only on iris-infrastructure and iris-gitops; it leaves active
   Terraform rulesets in place. Never run migration deletion merely to bypass a failed check.

Rulesets and classic branch protection can both apply. The verifier checks the owned ruleset;
it does not prove there are no other organization or classic restrictions.

## Day-2 and recovery

Changes remain PR -> CI -> operator merge -> `production-infra.yml` (stage governance). Dispatch is for retries
or reconciliation without a new commit:

```bash
gh workflow run production-infra.yml \
  --repo chiendz11/iris-infrastructure --ref main --field scope=governance
```

Terraform `prevent_destroy` and the saved-plan guard reject accidental ruleset deletion/replacement.
If a wrong required-check name locks all merges, repair only the offending rule using the owner
account, record the break-glass action, repair Git and reconcile Terraform. Do not keep a permanent
bypass or delete the state.

PR plans do not receive App write credentials and explicitly disable live discovery/imports.
They use existing state with `-refresh=false`; a create in a first-adoption PR is speculative,
not evidence the remote object is absent. The protected job discovers and refreshes before its
saved plan/apply. Do not expose the governance App private key to PR-controlled code or apply a
discovery-disabled speculative plan. Native provider discovery handles only complete API lists;
if a next-page link appears, extend the implementation before retrying (never silently ignore it).

See `SOLO_OPERATION.md` for the full solo migration and `ROLLBACK_RUNBOOK.md` for cross-repository
recovery. These runbooks describe procedures; they do not imply a restore drill has been performed.
