# GitHub control plane

## Ownership and identities

The GitHub control plane separates policy, non-secret configuration, intent transport and desired
state mutation:

```text
terraform/github-governance -> protect-main rulesets
terraform/github-config     -> non-secret Actions variables + app prod Environments
iris-inference-publisher    -> inference workflow dispatch only
iris-model-registry-publisher -> registry workflow dispatch only
iris-model-release-publisher -> in-cluster model workflow dispatch only
iris-platform-contract-publisher -> platform workflow dispatch only
iris-gitops-automation      -> branches and protected GitOps pull requests only
GitHub Settings             -> App creation/private keys + infrastructure prod gate
```

`iris-infrastructure/prod` is intentionally not managed by `terraform/github-config`. That
Environment releases credentials capable of changing the configuration root itself; letting the
same root manage its own root-of-trust boundary would create a circular trust boundary.

The three application `prod` Environments are Terraform-owned. They allow deployments only from
protected branches and disable admin bypass. The personal repository owner (`github_owner`, currently
`chiendz11`) is the required deployment reviewer and `prevent_self_review=false` allows self-approval.
This is separate from PR rules: PRs do not require approval by a second person.
There is one production environment only; no staging Environment or variable set is created.

## One-time root-of-trust setup

1. Keep `.github/CODEOWNERS` as ownership documentation. Solo rulesets require PR/CI, not a second
   reviewer. Follow `SOLO_OPERATION.md` to enable the owner's deployment approval gates.
2. Bootstrap `terraform/bootstrap` locally and migrate its state to S3 as documented in
   `AWS_DEPLOYMENT.md`.
3. Run the day-0 bridge once with an owner credential:

   ```bash
   ./scripts/configure-github.sh \
     example.com \
     arn:aws:iam::123456789012:role/eks-admin
   ```

   This configures `iris-infrastructure/prod` and seeds backend/OIDC metadata. Once
   `terraform/github-config` is adopted, do not use it for normal updates.
4. Create the seven Apps from the reviewed examples in `github-apps/` and install them on exactly the
   repositories listed there. Do not enable webhooks.
5. Configure root control-plane credentials:

   ```bash
   gh variable set GOVERNANCE_APP_CLIENT_ID --repo chiendz11/iris-infrastructure --env prod \
     --body '<governance-client-id>'
   gh secret set GOVERNANCE_APP_PRIVATE_KEY --repo chiendz11/iris-infrastructure --env prod \
     < /secure/path/iris-governance.pem

   gh variable set CONFIG_SYNC_APP_CLIENT_ID --repo chiendz11/iris-infrastructure --env prod \
     --body '<configuration-client-id>'
   gh secret set CONFIG_SYNC_APP_PRIVATE_KEY --repo chiendz11/iris-infrastructure --env prod \
     < /secure/path/iris-configuration.pem

   # Repository scope supports PR plans; prod scope releases reviewed configuration.
   for scope in "" "--env prod"; do
     gh variable set INFERENCE_PUBLISHER_APP_CLIENT_ID \
       --repo chiendz11/iris-infrastructure ${scope} --body '<inference-client-id>'
     gh variable set MODEL_REGISTRY_PUBLISHER_APP_CLIENT_ID \
       --repo chiendz11/iris-infrastructure ${scope} --body '<registry-client-id>'
     gh variable set INFERENCE_PUBLISHER_ACTOR \
       --repo chiendz11/iris-infrastructure ${scope} --body 'iris-inference-publisher[bot]'
     gh variable set MODEL_REGISTRY_PUBLISHER_ACTOR \
       --repo chiendz11/iris-infrastructure ${scope} --body 'iris-model-registry-publisher[bot]'
     gh variable set MODEL_RELEASE_PUBLISHER_ACTOR \
       --repo chiendz11/iris-infrastructure ${scope} --body 'iris-model-release-publisher[bot]'
   done

   # Platform has a distinct Actions-only identity; set the exact bot login shown by GitHub.
   gh variable set PLATFORM_CONTRACT_PUBLISHER_APP_CLIENT_ID \
     --repo chiendz11/iris-infrastructure --body '<platform-publisher-client-id>'
   gh variable set PLATFORM_CONTRACT_PUBLISHER_APP_CLIENT_ID \
     --repo chiendz11/iris-infrastructure --env prod --body '<platform-publisher-client-id>'
   gh variable set PLATFORM_CONTRACT_PUBLISHER_ACTOR \
     --repo chiendz11/iris-infrastructure --body 'iris-platform-contract-publisher[bot]'
   gh variable set PLATFORM_CONTRACT_PUBLISHER_ACTOR \
     --repo chiendz11/iris-infrastructure --env prod \
     --body 'iris-platform-contract-publisher[bot]'
   gh secret set PLATFORM_CONTRACT_PUBLISHER_APP_PRIVATE_KEY \
     --repo chiendz11/iris-infrastructure --env prod \
     < /secure/path/iris-platform-contract-publisher.pem
   ```

6. Store each Actions-only publisher key only in its owning source repository's protected `prod`
   Environment:

   ```bash
   gh secret set INTENT_PUBLISHER_APP_PRIVATE_KEY \
     --repo chiendz11/iris-inference-service --env prod \
     < /secure/path/iris-inference-publisher.pem
   gh secret set INTENT_PUBLISHER_APP_PRIVATE_KEY \
     --repo chiendz11/iris-model-registry --env prod \
     < /secure/path/iris-model-registry-publisher.pem
   ```

   `terraform/github-config` publishes the matching non-secret Client ID and `GITOPS_REPOSITORY` to
   each Environment. Data pipeline CI needs no GitHub App key: the in-cluster dispatcher has a
   separate identity. Source repositories never checkout `iris-gitops`.
7. After `terraform/platform` creates both secret containers, seed the in-cluster publisher and
   receiver renderer credentials:

   ```bash
   ./scripts/seed-github-app-secret.sh \
     model-release-publisher \
     '<model-release-publisher-client-id>' \
     /secure/path/iris-model-release-publisher.pem

   ./scripts/seed-github-app-secret.sh \
     gitops-automation \
     '<gitops-automation-client-id>' \
     /secure/path/iris-gitops-automation.pem
   ```

   Terraform owns the Secrets Manager containers and least-privilege policies, never either secret
   value. Delete plaintext working copies after putting recovery keys in a password manager.

## Contract transport trust boundary

Each producer mints a one-hour installation token for its dedicated publisher App. Every publisher
has only Actions write on `iris-gitops`, sufficient for cross-repository `workflow_dispatch` but not
for branch, manifest or pull-request mutation. The receiver selects the allowed actor from the
validated component and rejects a bot belonging to another producer.

Infrastructure does not share that producer identity. After `terraform/github-config` has applied
the trusted receiver variables, it mints `iris-platform-contract-publisher`. The GitOps platform
receiver rejects any actor other than the exact bot login in
`PLATFORM_RECONCILE_ALLOWED_ACTOR`. Thus a leaked application/in-cluster publisher key cannot ask
the platform receiver to use its GitOps PR credential. The dispatch JSON never contains the
receiver role or secret ARN.

Trusted receiver workflows validate contracts on `iris-gitops/main`, render the sole production
desired state and then assume `GITOPS_AUTOMATION_AWS_ROLE_ARN` to read
`GITOPS_AUTOMATION_SECRET_ARN`. The resulting `iris-gitops-automation` installation token can open
a PR without bypassing the ruleset. Receiver workflows do not call merge; the operator merges after CI.
With zero required approvals, the App's Contents/PR write permissions may technically permit merging a
passing PR. Manual merge is workflow behavior, not a separately enforced human-only authorization gate.

The in-cluster model-release dispatcher receives its dedicated publisher credential through External Secrets.
It has the same Actions-only limitation as app CI. Fetch/train/evaluate Pods do not mount it.

## First adoption and normal lifecycle

GitHub configuration can adopt a partially configured account or create missing app configuration.
Native data sources list existing objects; conditional imports select only Terraform-owned names.
Variables in repository and prod scopes are handled independently. The infra prod approval gate
must already exist (owner bootstrap), and failed API/authentication checks are never treated as
missing objects. PR plans disable discovery so they need no privileged App credential.

The first GitHub configuration plan is marked `deferred-initial-adoption`: remote state does not yet
contain GitHub resource IDs and PR-controlled code receives no write credential. After merge and
owner approval of the protected-branch `prod` job, it refreshes GitHub, imports existing Environments/variables, saves
an exact plan, blocks Environment deletion/replacement and applies it.

```text
PR: fmt + validate + existing-state speculative plan
  -> operator checks the diff + pr-gate
  -> merge main -> owner approves prod deployment
  -> short-lived configuration App token
  -> refreshed plan + destructive guard + apply
```

Foundation and platform are connected by `production-infra.yml`, using local reusable workflows
at one commit. The shared path classifier and explicit `needs` replace distributed dispatch routing.

```text
foundation → github-config-before → optional domain/platform
platform → github-config-after → handoff → dedicated App dispatch to GitOps
```

Both config jobs use the same reusable implementation. Foundation outputs are explicit inputs, not
an assumption that freshly updated GitHub Variables refresh within the running workflow. Configuration
discovery treats only S3 NotFound as absent state; auth/network errors fail closed.

Handoff reads authoritative platform state and requires a refreshed no-diff plan before publishing.
It checks runtime credential versions without reading values. After day-0 manual seed, rerun failed
jobs at the current main revision or select `scope=handoff`; no AWS apply is performed in that scope.

No script writes Variables during normal operation. Map newly selected outputs in
`terraform/github-config/main.tf`; Terraform owns reconciliation. The old app configuration helper
remains an explicitly enabled break-glass bridge only.

```bash
gh workflow run production-infra.yml \
  --repo chiendz11/iris-infrastructure --ref main --field scope=github-config
```

See `WORKFLOW_ORCHESTRATION.md` for stages, approvals, retries, and the separate DNS boundary.

## Secret boundary## Secret boundary

- Terraform manages non-secret values: regions, bucket/repository names, role/secret ARNs and App
  Client IDs. A secret ARN is a reference, not a secret value.
- Governance/configuration/application-publisher/platform-publisher private keys stay in protected GitHub Environment secrets and
  only mint one-hour tokens in post-merge jobs.
- The in-cluster publisher credential and GitOps PR credential use separate Secrets Manager
  containers. External Secrets may read only the publisher credential; a branch-bound OIDC role may
  read only the GitOps automation credential.
- RDS manages its master password in Secrets Manager; Kubernetes receives it through External
  Secrets.
- No static AWS access key, PAT or long-lived `GITOPS_TOKEN` is used.

Because these repositories use a personal account, App setup remains a manual root of trust. No PEM
is duplicated between producer repositories; a GitHub organization can later use organization
policy or trusted reusable workflows while preserving the component identity boundary.
