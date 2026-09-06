# GitHub control plane: Stage 1

## Ownership

Stage 1 separates policy, non-secret configuration and credentials:

```text
terraform/github-governance -> protect-main rulesets
terraform/github-config     -> non-secret Actions variables + app prod Environments
GitHub Settings (root trust) -> App creation/private keys + infrastructure prod gate
```

`iris-infrastructure/prod` is intentionally not managed by `terraform/github-config`. That
Environment releases the App key and OIDC role capable of changing the GitHub configuration root;
letting the same root manage its own approval gate would create a circular trust boundary.

The three application `prod` Environments are Terraform-owned. They allow deployments only from
protected branches, disable admin bypass, prevent self-review, and require at least one reviewer
whose login differs from the repository owner. The reviewer must already be a collaborator.

## One-time root-of-trust setup

1. Invite a mentor/second account as collaborator on all five repositories. Add that real login to
   every `.github/CODEOWNERS`, for example `* @chiendz11 @mentor-login`, through normal PRs. A
   CODEOWNERS file cannot consume a Terraform/GitHub variable, so this identity-specific source line
   cannot be generated safely before the login is known. The bootstrap script verifies that each
   supplied reviewer is already a collaborator on all five repos.
2. Bootstrap `terraform/bootstrap` locally and migrate its state to S3 as documented in
   `AWS_DEPLOYMENT.md`.
3. Keep `iris-infrastructure/prod` outside Terraform. The day-0 bridge in the next step creates or
   updates it through the GitHub API with admin bypass disabled, self-review prevented, protected
   branches only and the supplied independent reviewer.
4. Run that root-of-trust bridge once with an owner credential:

   ```bash
   ./scripts/configure-github.sh \
     example.com \
     arn:aws:iam::123456789012:role/eks-admin \
     '["mentor-github-login"]'
   ```

   It seeds backend/OIDC metadata at repository and `prod` scope so the first CI jobs can start.
   Once `terraform/github-config` is adopted, do not use this script for normal updates.
5. Create the three control-plane Apps using the reviewed examples in `github-apps/` and install
   them on exactly the listed repositories. Do not enable webhooks. The fourth manifest,
   `iris-model-promoter`, follows the separate runtime-secret procedure below.
6. Configure `iris-infrastructure/prod`:

   ```bash
   gh variable set GOVERNANCE_APP_CLIENT_ID --repo chiendz11/iris-infrastructure --env prod \
     --body '<governance-client-id>'
   gh secret set GOVERNANCE_APP_PRIVATE_KEY --repo chiendz11/iris-infrastructure --env prod \
     < /secure/path/iris-governance.pem

   gh variable set CONFIG_SYNC_APP_CLIENT_ID --repo chiendz11/iris-infrastructure --env prod \
     --body '<configuration-client-id>'
   gh secret set CONFIG_SYNC_APP_PRIVATE_KEY --repo chiendz11/iris-infrastructure --env prod \
     < /secure/path/iris-configuration.pem

   # Repository scope is used by credential-free PR plans; prod scope by apply.
   gh variable set GITOPS_APP_CLIENT_ID --repo chiendz11/iris-infrastructure \
     --body '<gitops-bot-client-id>'
   gh variable set GITOPS_APP_CLIENT_ID --repo chiendz11/iris-infrastructure --env prod \
     --body '<gitops-bot-client-id>'
   gh secret set GITOPS_APP_PRIVATE_KEY --repo chiendz11/iris-infrastructure --env prod \
     < /secure/path/iris-gitops-bot.pem
   ```

7. Put the GitOps App private key in the two source repositories that open deployment PRs:

   ```bash
   gh secret set GITOPS_APP_PRIVATE_KEY --repo chiendz11/iris-model-registry --env prod \
     < /secure/path/iris-gitops-bot.pem
   gh secret set GITOPS_APP_PRIVATE_KEY --repo chiendz11/iris-inference-service --env prod \
     < /secure/path/iris-gitops-bot.pem
   ```

   `GITOPS_APP_CLIENT_ID` in those repos is not manual: `terraform/github-config` propagates it.
   The data-pipeline repo does not currently open a GitOps PR and therefore does not receive this
   credential.

8. Delete the plaintext PEM copies after storing them in a password manager/recovery vault. Never
   put these three control-plane keys in tfvars, Terraform variables, AWS Secrets Manager runtime
   paths or the repository.

## Model promotion App

Create `iris-model-promoter` from its reviewed manifest and install it only on `iris-gitops`.
Unlike the three control-plane Apps above, this runtime credential is stored once in AWS Secrets
Manager. Chỉ Dispatch Pod chạy DevOps-owned dispatcher image nhận key để phát release-intent
contract; fetch/train/smoke/evaluate Pod không nhận key. The trusted workflow on the default branch
of `iris-gitops` reads the same secret through a dedicated OIDC role and uses it to open the
protected rollout PR. After `terraform/platform` has created its empty Secrets Manager container,
seed it from an operator workstation:

```bash
./scripts/seed-model-promoter-secret.sh \
  '<model-promoter-client-id>' \
  /secure/path/iris-model-promoter.pem
```

Do this before merging the initial infrastructure-output PR that enables the production data
pipeline, or before publishing the first dataset event. The script reads the ARN from Terraform
output, writes a temporary mode-0600 JSON payload, creates a new secret version without printing
the payload and removes the temporary file. Keep the recovery PEM in a password manager.

This is deliberately a separate App from the configuration/governance identities: compromise of a
training pod cannot change repository settings/rulesets, access AWS through the GitOps OIDC role or
merge directly to protected `main`. Because the App must hold Contents/Pull requests permissions to
serve both sides of this capstone flow, such a pod could still create a branch or PR; GitOps branch
rules therefore remain a mandatory boundary with the `validate` check and independent CODEOWNER
review. A larger production platform should split dispatch and PR-writing into separate identities
behind an event broker.

## First adoption and normal lifecycle

The first GitHub configuration plan is marked `deferred-initial-adoption`: the remote state does not
yet contain GitHub resource IDs and PR-controlled code is not given a write App credential. After
merge and `prod` approval, the protected job refreshes GitHub, imports existing Environments and
variables, saves an exact plan, blocks Environment deletion/replacement, then applies that plan.

```text
PR: fmt + validate + existing-state speculative plan
  -> CODEOWNER review + pr-gate
  -> merge main
  -> prod approval
  -> short-lived configuration App token
  -> refreshed plan + destructive guard + apply
```

Foundation and platform are connected automatically:

```text
foundation apply
  -> terraform-github-config (new IAM/state outputs)
  -> optional domain -> optional platform

platform apply
  -> terraform-github-config (ECR/DVC/deploy-role/dispatcher outputs)
  -> application prod variables and GitOps automation metadata updated
```

No output-sync shell script is called in the normal lifecycle. Adding a selected output still
requires a reviewed mapping in `terraform/github-config/main.tf`; Terraform then detects and applies
the corresponding GitHub variable diff.

`workflow_dispatch` remains only for drift reconciliation/recovery:

```bash
gh workflow run terraform-github-config.yml \
  --repo chiendz11/iris-infrastructure \
  --ref main \
  --field source=manual
```

## Secret boundary

- Terraform manages values that are non-secret: regions, bucket/repository names, role ARNs and the
  GitOps App Client ID propagated to app repos. Root App Client IDs and reviewer input remain in the
  out-of-band infrastructure gate; Terraform enforces the resulting app Environment policy.
- Control-plane App private keys stay in protected GitHub Environment secrets and only mint
  one-hour installation tokens in trusted post-merge jobs.
- The model-promoter App is a runtime exception: its value lives only in AWS Secrets Manager. It
  reaches Argo through External Secrets and the GitOps release workflow through a dedicated,
  repository/branch-bound OIDC role; Terraform owns the container and both least-privilege access
  policies, not the secret value.
- AWS workload secrets stay in Secrets Manager and reach Kubernetes through External Secrets.
- No static AWS access key and no long-lived `GITOPS_TOKEN`/PAT is used.

Because the repositories currently belong to a personal account, the same GitOps App PEM has to be
stored in each consuming repo's `prod` Environment. In a GitHub organization, a central secret
broker or organization-level reusable workflow can reduce duplication while preserving the same
short-lived token boundary.
