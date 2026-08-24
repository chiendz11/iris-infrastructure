from __future__ import annotations

import argparse
import json
import re
from pathlib import Path
from typing import Any


def load_outputs(path: Path) -> dict[str, Any]:
    raw = json.loads(path.read_text(encoding="utf-8"))
    return {name: item["value"] for name, item in raw.items()}


def replace(path: Path, pattern: str, replacement: str, *, count: int = 0) -> None:
    original = path.read_text(encoding="utf-8")
    updated, matches = re.subn(pattern, replacement, original, count=count, flags=re.MULTILINE)
    if matches == 0:
        raise RuntimeError(f"Expected pattern was not found in {path}: {pattern}")
    path.write_text(updated, encoding="utf-8")


def main() -> None:
    parser = argparse.ArgumentParser(description="Render Terraform outputs into iris-gitops.")
    parser.add_argument("--outputs", required=True, type=Path)
    parser.add_argument("--gitops", required=True, type=Path)
    args = parser.parse_args()

    output = load_outputs(args.outputs)
    root = args.gitops
    roles = output["service_account_role_arns"]
    repositories = output["ecr_repository_urls"]

    lbc = root / "applications/platform-aws-load-balancer-controller.yaml"
    replace(lbc, r"^(\s*clusterName:)\s+.*$", rf"\1 {output['cluster_name']}")
    replace(lbc, r"^(\s*vpcId:)\s+.*$", rf"\1 {output['vpc_id']}")
    replace(
        lbc,
        r"^(\s*eks\.amazonaws\.com/role-arn:)\s+.*$",
        rf"\1 {output['aws_load_balancer_controller_role_arn']}",
    )

    external_dns = root / "applications/platform-external-dns.yaml"
    replace(
        external_dns,
        r"^(\s*eks\.amazonaws\.com/role-arn:)\s+.*$",
        rf"\1 {output['external_dns_role_arn']}",
    )
    replace(
        external_dns,
        r"(domainFilters:\n\s*- )[^\n]+",
        rf"\1{output['public_domain_name']}",
    )
    replace(
        external_dns,
        r"^(\s*zone-id-filter:)\s+.*$",
        rf"\1 {output['route53_zone_id']}",
    )

    knative = root / "platform/knative/kustomization.yaml"
    replace(
        knative,
        r"^(\s*service\.beta\.kubernetes\.io/aws-load-balancer-ssl-cert:)\s+.*$",
        rf"\1 {output['public_certificate_arn']}",
    )
    replace(
        knative,
        r"^(\s*external-dns\.alpha\.kubernetes\.io/hostname:)\s+.*$",
        rf"\1 {output['kserve_hostname']}",
    )

    domain_mapping = root / "environments/production/inference-service/domain-mapping.yaml"
    replace(domain_mapping, r"^  name: .+$", f"  name: {output['kserve_hostname']}")

    infrastructure_values = {
        "applications/platform-external-secrets.yaml": (
            r"^(\s*eks\.amazonaws\.com/role-arn:)\s+.*$",
            rf"\1 {roles['external_secrets']}",
        ),
        "environments/production/data-pipeline/artifact-repository.yaml": (
            r"^(\s*bucket:)\s+.*$",
            rf"\1 {output['argo_artifact_bucket']}",
        ),
        "environments/production/data-pipeline/eventsource.yaml": (
            r"^(\s*queue:)\s+.*$",
            rf"\1 {output['dataset_event_queue_name']}",
        ),
        "environments/production/data-pipeline/rbac.yaml": (
            r"^(\s*eks\.amazonaws\.com/role-arn:)\s+.*$",
            rf"\1 {roles['training']}",
        ),
        "environments/production/model-registry/service-account.yaml": (
            r"^(\s*eks\.amazonaws\.com/role-arn:)\s+.*$",
            rf"\1 {roles['mlflow']}",
        ),
    }
    for relative_path, (pattern, replacement) in infrastructure_values.items():
        replace(root / relative_path, pattern, replacement)

    eventsource = root / "environments/production/data-pipeline/eventsource.yaml"
    replace(
        eventsource,
        r"^(\s*eks\.amazonaws\.com/role-arn:)\s+.*$",
        rf"\1 {roles['argo_events']}",
    )

    workflow = root / "environments/production/data-pipeline/workflow-template.yaml"
    replace(
        workflow,
        r"^(\s*- \{name: dataset-bucket, value:)\s+[^}]+(\})$",
        rf"\1 {output['dvc_bucket']}\2",
    )

    registry = root / "environments/production/model-registry/kustomization.yaml"
    replace(registry, r"^(\s*- POSTGRES_HOST=).*$", rf"\1{output['rds_endpoint']}")
    replace(
        registry,
        r"^(\s*- MLFLOW_ARTIFACT_BUCKET=).*$",
        rf"\1{output['mlflow_artifact_bucket']}",
    )
    replace(registry, r"^(\s*newName:)\s+.*$", rf"\1 {repositories['mlflow']}")

    secret = root / "environments/production/model-registry/external-secret.yaml"
    replace(
        secret,
        r"(remoteRef: \{key:)\s+[^,]+(, property: (?:username|password)\})",
        rf"\1 {output['rds_master_secret_arn']}\2",
    )


if __name__ == "__main__":
    main()
