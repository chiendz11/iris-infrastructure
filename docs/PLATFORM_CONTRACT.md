# Platform contract v1

## Ownership boundary

`iris-infrastructure` is the producer of non-secret AWS platform metadata. Its public API is
`contracts/platform-contract-v1.schema.json`; `scripts/build_platform_contract.py` maps a strict
allowlist of `terraform output -json` values into that API and validates the result before it can
leave the repository.

The producer deliberately has no knowledge of Kubernetes resource names, Kustomize files,
Application paths or replacement syntax. `iris-gitops` owns `platform-reconcile.yml`, validates the
same contract version and decides how fields map into the sole `environments/production` desired
state. Adding staging later requires a new reviewed routing design; it is not pre-created now.

```text
terraform/platform apply
        |
        v
selected non-secret outputs
        |
        v
build_platform_contract.py -- schema validation
        |
        v
verify runtime App secret versions exist (metadata only)
        |
        v
terraform/github-config applies trusted GitOps receiver variables
        |
        v
dedicated publisher -> platform-reconcile.yml (one JSON input)
        |
        v
iris-gitops renderer -> protected PR -> Argo CD
```

## Contract envelope

Every event carries immutable provenance:

- `contract_version`: exactly `v1`;
- `producer`: exactly `iris-infrastructure`;
- `environment`: exactly `production`;
- `source_repository`, `source_sha` and `change_id`: identify the applied source and workflow run.

The payload groups platform data by stable concepts:

- `cluster`: EKS cluster name and VPC ID;
- `storage`: DVC, MLflow and Argo artifact buckets;
- `events`: dataset SQS queue name, URL and ARN;
- `registry`: RDS endpoint and the ARN of its RDS-managed secret, never its value;
- `ecr_repositories`: repository name and URL for training, inference, MLflow and dispatcher;
- `iam_roles`: workload/controller IRSA ARNs;
- `automation.model_release_publisher_secret_arn`: Secrets Manager reference used by the
  in-cluster model-release publisher;
- `domain`: apex domain, flat KServe hostname, Route53 zone, ACM certificate and public URL.

The receiver's OIDC role and Secrets Manager ARN are deliberately absent. If a dispatch payload
could select either value, a compromised Actions-only publisher could turn the receiver into a
confused deputy and ask it to read another secret. Those two references are trusted control-plane
configuration, not platform data, and come only from Terraform-managed GitOps repository variables.

`additionalProperties: false` at the envelope and nested object levels prevents an accidental new
Terraform output from silently crossing the repository boundary. The builder also rejects any
selected Terraform output marked `sensitive=true`.

## Transport and credentials

The orchestrator waits for `github-config-after` to reconcile trusted receiver Variables before
calling `reusable-platform-handoff.yml`. Handoff reads platform state, requires a refreshed no-diff
plan, and builds/schema-validates the contract. It does not accept a caller-supplied contract JSON.
It then uses the dedicated platform-publisher App (Actions write only) to dispatch the GitOps receiver.
Infrastructure cannot edit GitOps contents or open PRs.

Local reusable workflows execute at the caller commit. Each protected job checks trusted repo/main,
checkout SHA and current remote main before credentials; stale runs stop rather than silently apply
new code. Handoff checks again just before minting/publishing. The former `source=platform` and
`github-actions[bot]` checks belonged to an internal dispatch protocol that no longer exists; the
replacement trusts the approved caller/state, not an operator-supplied payload. The GitOps receiver's
exact publisher bot check is unchanged.

The receiver owns PR creation. Before assuming AWS identity, it compares `github.actor` to the exact
dedicated App bot stored in the trusted repository variable. Its `iris-gitops-automation` credential
is kept in AWS Secrets Manager and read through a branch-bound OIDC role whose ARN is also a trusted
repository variable. Contract data can therefore influence rendering but cannot influence how the
receiver authenticates. Every rendered change still goes through a protected PR and CI before operator merge.

The handoff job checks `DescribeSecret.VersionIdsToStages` for `AWSCURRENT` on both runtime App
containers before handoff. It reads those ARNs directly from `terraform output -json`, not from the
contract, and never calls `GetSecretValue`. On day 0 the first apply can therefore provision the
containers and stop safely; after the operator seeds them, scope=handoff reconciles GitHub config
and publishes without AWS apply. A pending platform diff blocks this path.

`source_repository` and `source_sha` remain useful audit provenance but are payload claims, not a
cryptographic attestation. The effective source boundary is the dedicated publisher private key
released only after owner self-approval of `iris-infrastructure/prod`, the exact bot-actor check,
protected-branch Environment access, and the protected GitOps PR (solo: no required PR reviewer). If stronger cross-system non-repudiation is required later,
sign the contract with KMS and verify the signature in the receiver.

## Compatibility rules

- A non-breaking optional addition still requires coordinated producer/consumer review because the
  schema rejects unknown fields.
- Removing or renaming a field, changing meaning, or changing a type requires `v2`, a new schema and
  a receiver migration.
- The physical ECR component key remains `dispatcher` in v1 for compatibility; GitOps may name the
  workload `release-automation` internally.
- Contract JSON is audit metadata and contains no secret values. It may be printed in the protected
  apply job summary.

Run producer tests locally with:

```bash
python -m pip install -r requirements-contract.txt
python -m unittest discover -s tests -v
```
