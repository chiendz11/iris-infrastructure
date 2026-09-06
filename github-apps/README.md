# GitHub App definitions

These manifest examples document the minimum repository permissions for the three control-plane
identities. GitHub App creation, installation and private-key generation remain a manual root of
trust; Terraform must never ingest the PEM.

| App | Install only on | Permission |
|---|---|---|
| `iris-governance` | all five Iris repositories | Administration: write |
| `iris-configuration` | all five Iris repositories | Administration, Environments, Variables: write |
| `iris-gitops-bot` | `iris-gitops` | Contents, Pull requests: write |
| `iris-model-promoter` | `iris-gitops` | Contents, Pull requests: write |

No App needs a webhook or subscribed event. Review the manifest in Git, then create the App from
GitHub Settings and compare the UI permission summary before installing it. App manifests bootstrap
configuration but are not an ongoing source of truth after creation, so later permission changes
must be reviewed both here and in GitHub Settings.

Store control-plane Client IDs as GitHub variables and PEM values as `prod` Environment secrets
according to `docs/GITHUB_CONTROL_PLANE.md`. `iris-model-promoter` is the exception: only the
DevOps-owned Dispatch Pod uses it to dispatch release intent and the GitOps workflow uses it to open
a PR, so its Client ID/private key JSON is stored once in AWS Secrets Manager. External Secrets
serves the Dispatch Pod; GitHub OIDC gives the GitOps workflow read-only access. Generate a separate
private key per App, keep the recovery copy in a password manager, and rotate one App at a time.
