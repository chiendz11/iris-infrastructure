# GitHub App definitions

These manifest examples document the minimum repository permissions for the control-plane and
contract-automation identities. GitHub App creation, installation and private-key generation remain a manual root of
trust; Terraform must never ingest the PEM.

| App | Install only on | Permission |
|---|---|---|
| `iris-governance` | all five Iris repositories | Administration: write |
| `iris-configuration` | all five Iris repositories | Administration, Environments, Variables: write |
| `iris-inference-publisher` | `iris-gitops` | Actions: write |
| `iris-model-registry-publisher` | `iris-gitops` | Actions: write |
| `iris-model-release-publisher` | `iris-gitops` | Actions: write |
| `iris-platform-contract-publisher` | `iris-gitops` | Actions: write |
| `iris-gitops-automation` | `iris-gitops` | Contents, Pull requests: write |

No App needs a webhook or subscribed event. Review the manifest in Git, then create the App from
GitHub Settings and compare the UI permission summary before installing it. App manifests bootstrap
configuration but are not an ongoing source of truth after creation, so later permission changes
must be reviewed both here and in GitHub Settings.

Store control-plane Client IDs as GitHub variables and PEM values as `prod` Environment secrets
according to `docs/GITHUB_CONTROL_PLANE.md`. Inference and model-registry each receive only their
own publisher key in their protected `prod` Environment. The in-cluster model-release publisher is
stored only in its dedicated Secrets Manager container. Each App can dispatch a trusted workflow
but cannot write repository content; distinct bot actors stop one compromised producer from
claiming another component in a payload.

The platform publisher key exists only in `iris-infrastructure/prod`. Its separate bot identity lets
`platform-reconcile.yml` reject dispatches made with an application/in-cluster publisher, even
though all publisher Apps have only Actions write.

The separate `iris-gitops-automation` credential is stored only in Secrets Manager. Trusted GitOps
renderer workflows assume a branch-bound OIDC role to read it and open protected desired-state PRs.
Generate a separate private key per App, keep recovery copies in a password manager, and rotate one
App at a time.
