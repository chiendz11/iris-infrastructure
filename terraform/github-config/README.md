# GitHub configuration Terraform root

This root is the source of truth for non-secret GitHub Actions variables, the three application
repositories' protected `prod` Environments and model-release/dispatcher metadata in
`iris-gitops`. It reads foundation/platform remote-state outputs and publishes only selected
values.

It deliberately does **not** manage:

- GitHub Actions secrets or GitHub App private keys;
- the `iris-infrastructure/prod` Environment, because that is the out-of-band root-of-trust gate;
- repository rulesets, which belong to `terraform/github-governance`;
- Kubernetes resources, which belong to Argo CD and `iris-gitops`.

The first reconcile imports the existing app Environments and variables created by the old scripts.
Once adopted, normal changes are PR -> `plan-github-config` -> merge -> `prod` approval -> apply.
The protected apply workflow mints a short-lived token from the dedicated configuration GitHub App.

`manage_application_config=false` is used before the platform state exists. After platform apply,
CI detects that state, enables application configuration and enforces at least one production
reviewer other than the repository owner.

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
