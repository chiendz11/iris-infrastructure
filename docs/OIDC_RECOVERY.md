# Recover GitHub OIDC trust without weakening it

GitHub's immutable subject includes owner/repository IDs. These repositories use
`repo:OWNER@OWNER_ID/REPO@REPO_ID`, not the older `repo:OWNER/REPO` prefix.
The IDs are public identity metadata, not secrets. Terraform pins their exact
prefixes; changing or recreating repositories requires an explicit reviewed update.

Read the authoritative configuration without fetching or logging an OIDC token:

```bash
gh api repos/chiendz11/iris-infrastructure/actions/oidc/customization/sub
```

`terraform/bootstrap/variables.tf` configures `github_oidc_subject_prefix`.
`terraform/platform/variables.tf` configures `github_oidc_subject_prefixes` for
the three app repositories and GitOps. Use the API for each repository when
forking/transferring this project; do not guess IDs or add `repo:*` wildcards.

The existing context boundaries remain unchanged:

- Foundation plan roles: `PREFIX:pull_request`.
- Foundation apply roles and application publishers: `PREFIX:environment:prod`.
- GitOps automation and its image publisher: `PREFIX:ref:refs/heads/main`.
- All roles still require audience `sts.amazonaws.com`.

## When CI cannot assume its own foundation role

This is a one-time repair using the existing operator credential. CI cannot
update its own trust policy until it can authenticate. Do not merge past a red
PR gate, switch to static AWS keys, or destroy/recreate the backend.

1. Review/checkout the fixed feature commit locally. Keep the existing
   `terraform/bootstrap/terraform.tfvars`, `backend.tf`, and `backend.hcl`.
   Do not copy example files over those working files.
2. Confirm `aws sts get-caller-identity --profile default` identifies the intended
   administrative IAM user/account. The profile name does not imply root.
3. Initialize the **existing** remote backend and review the full foundation plan:

   ```bash
   export AWS_PROFILE=default
   export AWS_REGION=ap-southeast-1
   terraform -chdir=terraform/bootstrap init -backend-config=backend.hcl
   terraform -chdir=terraform/bootstrap plan -out=oidc-trust.tfplan
   terraform -chdir=terraform/bootstrap show -no-color oidc-trust.tfplan
   ```

   For this repair, expect only in-place trust-policy changes to the six
   foundation roles (plan/apply for Terraform, governance and GitHub config).
   Stop if the plan proposes unrelated changes, replacement, or deletion.
4. After reviewing, apply that exact saved plan yourself:

   ```bash
   terraform -chdir=terraform/bootstrap apply oidc-trust.tfplan
   ```

   This does not deploy EKS/RDS/domain; it updates the existing foundation stack.
   State remains in the original S3 backend. Plan files must not be committed.
5. Rerun failed jobs on the latest fixed PR run (not an older run without the code
   fix). If main/PR source changed, review the new revision before retrying.
6. Wait for the aggregate `pr-gate`. After it passes, follow the normal reviewed
   merge and prod-approval deployment flow. Platform creates its publisher roles
   with the corrected subjects on its normal apply; no separate platform apply is
   needed to recover the initial foundation authentication failure.

Official references:
[GitHub immutable subjects](https://github.blog/changelog/2026-04-23-immutable-subject-claims-for-github-actions-oidc-tokens/),
[OIDC repository API](https://docs.github.com/en/rest/actions/oidc).
