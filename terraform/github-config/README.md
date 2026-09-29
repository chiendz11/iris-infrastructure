# GitHub configuration Terraform root

This root is the source of truth for non-secret GitHub Actions variables, the three application
repositories' protected `prod` Environments and GitOps/release-automation metadata in
`iris-gitops`. It reads foundation/platform remote-state outputs and publishes only selected
values.

Each application receives a different `AWS_DEPLOY_ROLE_ARN`: data pipeline can publish only the
training image and DVC objects, model registry only the MLflow image, and inference only its serving
image. The roles are not interchangeable even though the variable name is the same in each repo.
Inference and model-registry also receive different GitHub App Client IDs. GitOps receives distinct
allowed bot actors for inference, registry, in-cluster model release and platform handoff; Terraform
rejects a configuration that reuses one actor across these trust boundaries.

It deliberately does **not** manage:

- GitHub Actions secrets or GitHub App private keys;
- the `iris-infrastructure/prod` Environment, because that is the out-of-band root-of-trust gate;
- repository rulesets, which belong to `terraform/github-governance`;
- Kubernetes resources, which belong to Argo CD and `iris-gitops`.

Protected reconcile discovers existing Environments and variables with native GitHub provider
data sources. It imports only names managed by this root that actually exist; missing app
Environments/variables are created by the resource declarations. It covers infrastructure
repository/prod variables, app prod variables and GitOps repository variables, not only legacy names.
Unrelated names are never imported. A GitHub permission/API error fails the plan, not "create all".
The infrastructure prod Environment itself is still an owner-managed prerequisite; a postcondition
fails with a bootstrap instruction if that trust gate is missing.

`discover_existing_configuration=true` is the default for trusted apply. PR CI explicitly sets it
to `false` and uses `-refresh=false`: no live configuration discovery or App write credential is
released to PR code. Its speculative plan can therefore show creates for not-yet-adopted objects;
the protected refreshed plan discovers/imports them before apply. Do not apply a PR plan directly.
Resource addresses are unchanged, so objects already in state continue to reconcile normally.
Offline regression tests run with mock GitHub providers and overridden AWS state data:

```bash
terraform init -backend=false
terraform test -filter=tests/adoption.tftest.hcl
```

Once adopted, normal changes are PR -> `plan-github-config` -> merge -> owner self-approves `prod` -> apply.
The protected apply workflow mints a short-lived token from the dedicated configuration GitHub App.

`manage_application_config=false` is used before the platform state exists. After platform apply,
CI detects that state and enables application configuration. `data.github_user.deployment_approver`
resolves the personal `github_owner` (currently `chiendz11`) as the required deployment reviewer of all
three app Environments. `prevent_self_review=false` permits the owner to approve their own runs;
PR approval requirements remain zero. There is no `production_reviewer_usernames` input.
The root also publishes the exact dedicated platform-publisher
bot login to `iris-gitops`; the receiver compares `github.actor` to that trusted variable before it
uses any AWS or pull-request credential.

For a local break-glass run, obtain a short-lived installation token with Repository
Administration, Environments and Variables write access to all five managed repositories, then:

```bash
cp backend.hcl.example backend.hcl
export GITHUB_TOKEN='<short-lived-installation-token>'
terraform init -backend-config=backend.hcl
terraform plan -var-file=terraform.tfvars
terraform apply -var-file=terraform.tfvars
unset GITHUB_TOKEN
```

Never place the App private key or installation token in tfvars or Terraform state.
