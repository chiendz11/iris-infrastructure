# GitHub governance Terraform root

This root is the source of truth for the `protect-main` repository ruleset on all five Iris
repositories. It deliberately does not manage application code, AWS resources, GitHub Actions
secrets, or the Argo CD deployment lifecycle.

The rulesets already exist, so `import.tf` adopts their public IDs during the first plan/apply.
Do not remove those import blocks and do not create another `protect-main` ruleset manually.

Authentication is provided only through `GITHUB_TOKEN`. CI mints a one-hour GitHub App installation
token inside the protected `prod` job. For a local break-glass run, export a short-lived token with
Repository Administration read/write access to exactly these five repositories.

```bash
cp backend.hcl.example backend.hcl
# Fill the state bucket and KMS ARN created by terraform/bootstrap.

export GITHUB_TOKEN="<short-lived-installation-token>"
terraform init -backend-config=backend.hcl
terraform plan
terraform apply
unset GITHUB_TOKEN
```

The App token and private key must never be passed as Terraform variables, written to tfvars, or
stored in Terraform state.
