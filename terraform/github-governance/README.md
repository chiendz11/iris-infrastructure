# GitHub governance Terraform root

This root is the source of truth for the `protect-main` repository ruleset on all five Iris
repositories. It deliberately does not manage application code, AWS resources, GitHub Actions
secrets, or the Argo CD deployment lifecycle.

`import.tf` discovers policies using the native `github_rest_api` data source in the pinned
GitHub provider. There is no hardcoded account-specific ID list or discovery shell script:

- Exactly one repository-owned `protect-main` branch ruleset: verify its detail and import it.
- Successful empty match: `github_repository_ruleset.main` creates the missing ruleset.
- Other names and organization policies are not imported or modified.
- Duplicate names, wrong targets, incomplete metadata, pagination, HTTP 404/403 or other API
  failures stop the plan. Access failures never mean "create a new ruleset".

Leave `existing_ruleset_ids = {}` (the default). It is now an optional assertion of expected
identities for migrations, not an unconditional import list. Stale explicit IDs fail closed;
review/remove obsolete assertions from any local tfvars. No Terraform resource address or state
key is renamed. Once adopted, Terraform continues managing the existing resource in its state.

Protected apply enables `discover_existing_rulesets=true`, refreshes state and applies its saved
plan. PR CI disables discovery/imports and uses `-refresh=false`, without an App key. The PR plan
is speculative: a proposed create is not proof that no remote policy exists; the protected job
performs authoritative adoption. Do not apply a discovery-disabled PR plan.

Mock tests (`terraform test -filter=tests/adoption.tftest.hcl`) exercise fresh, mixed and unsafe
discovery responses without real GitHub credentials or operations. They run in PR static CI.

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
