# GitHub ruleset lifecycle

## Ownership boundary

`terraform/github-governance` is the only desired-state writer for repository rulesets. GitHub's
Settings UI is an inspection/break-glass surface, not the normal update path. The migration helper
only verifies effective rules and removes two legacy classic branch protections; it never creates
or updates a ruleset.

```text
Git pull request
      |
      v
Terraform configuration + reviewable plan
      |
      v
github_repository_ruleset
      |
      v
GitHub protect-main ruleset
```

State is isolated at `s3://<state-bucket>/infrastructure/github-governance.tfstate`. Dedicated OIDC
roles can access only that state object and its lock; the governance apply role has no permission to
mutate AWS infrastructure.

## Desired protection

All five rulesets target `~DEFAULT_BRANCH` and enforce:

- pull requests with one approval;
- CODEOWNER review and stale-review dismissal;
- approval of the last reviewable push by someone other than its author;
- resolved review threads;
- strict required status checks bound to GitHub Actions App integration ID `15368`;
- squash or rebase merge only and linear history;
- no force-push or branch deletion;
- no permanent bypass actor.

Required checks are stable aggregate jobs:

| Repository | Required check |
|---|---|
| `iris-infrastructure` | `pr-gate` |
| `iris-gitops` | `validate` |
| `iris-data-pipeline` | `ci-gate` |
| `iris-model-registry` | `ci-gate` |
| `iris-inference-service` | `ci-gate` |

When renaming a required check, first emit both old and new checks, then update the Terraform
ruleset, and only afterward remove the old check. Changing both sides in one PR can lock all merges.

## Root of trust

Terraform cannot safely create every credential that grants Terraform control over GitHub. Create
the dedicated governance App manually (the reviewed manifest is
`github-apps/iris-governance.manifest.example.json`):

1. Create `iris-governance` under the GitHub account settings; a webhook is not required.
2. Grant Repository permission `Administration: Read and write`; Metadata read is implicit.
3. Install it only on the five Iris repositories.
4. Create a private key.
5. In `iris-infrastructure` Environment `prod`, set variable `GOVERNANCE_APP_CLIENT_ID`.
6. In the same Environment, set secret `GOVERNANCE_APP_PRIVATE_KEY` to the PEM content.
7. Require an independent reviewer and allow deployments only from protected branches.

Example CLI configuration after the Environment exists:

```bash
gh variable set GOVERNANCE_APP_CLIENT_ID \
  --repo chiendz11/iris-infrastructure \
  --env prod \
  --body '<github-app-client-id>'

gh secret set GOVERNANCE_APP_PRIVATE_KEY \
  --repo chiendz11/iris-infrastructure \
  --env prod \
  < /path/to/iris-governance.private-key.pem
```

The PEM is a long-lived root credential, but the workflow never hands it to Terraform. A pinned
GitHub-maintained Action exchanges it for an installation token scoped to the five repositories;
the token expires after one hour and is revoked at job completion. Do not reuse this App as the
GitOps deployment-PR bot because that bot needs different Contents/Pull requests permissions.

## Initial adoption sequence

The rulesets already exist outside Terraform. Their public IDs are declared in `import.tf`, so the
first apply adopts them instead of creating a second active layer.

Use this order to avoid a dependency race:

1. Merge the `ci-gate` and `CODEOWNERS` changes in all three application repositories; confirm each
   new check has completed successfully at least once.
2. Reconcile `terraform/bootstrap` to create the dedicated governance plan/apply state roles.
3. Run the day-0 `scripts/configure-github.sh` bridge so governance/config role ARNs are written to
   repository and `prod` Environment variables. After GitHub configuration adoption, Terraform owns
   these values.
4. Create/install the GitHub App and configure its Client ID/private key as described above.
5. Merge the governance root/workflow to `iris-infrastructure/main`; approve its `prod` job. When
   the same merge also changes `terraform/bootstrap`, the direct governance run deliberately skips
   and `terraform-foundation.yml` dispatches a replacement run with the newly created governance
   role ARN. This preserves dependency order without a manual rerun.
6. The first plan imports all five existing `protect-main` resources, updates their review/check
   rules and records them in the isolated remote state.
7. Verify without mutation:

   ```bash
   GH_TOKEN='<administration-read-token>' scripts/migrate-rulesets.sh
   ```

8. Remove only the two pre-existing classic branch protections after verification:

   ```bash
   GH_TOKEN='<administration-write-token>' \
     scripts/migrate-rulesets.sh --remove-legacy
   ```

Classic protection and rulesets are cumulative. Skipping step 8 leaves two control planes active on
`iris-infrastructure` and `iris-gitops`, including the obsolete infrastructure check `static`.

## Normal day-2 lifecycle

```text
PR changes terraform/github-governance
        |
        +--> fmt/validate
        +--> speculative plan with state-only AWS plan role
             (no GitHub Administration credential)
        |
        v
pr-gate + CODEOWNER review
        |
        v
merge main
        |
        v
Environment prod approval
        |
        +--> mint short-lived GitHub App token
        +--> refreshed saved plan
        +--> reject delete/replace
        +--> apply exact plan
        +--> verify all effective rules through GitHub API
```

`workflow_dispatch` is only for drift reconciliation or recovery:

```bash
gh workflow run terraform-governance.yml \
  --repo chiendz11/iris-infrastructure \
  --ref main \
  --field source=manual
```

PR jobs never receive the App private key or a write token. The repositories are currently public,
so the GitHub provider can read existing rule metadata during import. If they become private, move
speculative planning to a trusted Terraform runner or use a separate read-only App credential behind
an approval gate; never expose the write App key to pull-request-controlled code.

## Break-glass

`lifecycle.prevent_destroy` blocks accidental ruleset deletion. If a bad check name or credential
change locks automation:

1. An account/repository owner temporarily disables the offending ruleset in GitHub Settings.
2. Repair the workflow/check or App installation and rotate the App private key if necessary.
3. Run Terraform locally with a short-lived Administration token, or rerun the protected workflow.
4. Confirm `scripts/migrate-rulesets.sh` passes and enforcement is `active` again.

Do not configure a permanent admin/App bypass merely to simplify the capstone. With one approval,
CODEOWNER review and last-push approval, a second human collaborator is required for PRs authored by
`chiendz11`.
