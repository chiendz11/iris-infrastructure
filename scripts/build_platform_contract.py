#!/usr/bin/env python3
"""Build the versioned, non-secret platform contract from Terraform outputs.

This producer deliberately knows only Terraform output names and the public
contract schema. GitOps file paths and rendering rules belong to iris-gitops.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any, NoReturn

from jsonschema import Draft202012Validator


CONTRACT_VERSION = "v1"
PRODUCER = "iris-infrastructure"
ECR_COMPONENTS = ("training", "inference", "mlflow", "dispatcher")


class ContractBuildError(ValueError):
    """Raised when Terraform output cannot produce a valid public contract."""


def fail(message: str) -> NoReturn:
    raise ContractBuildError(message)


def load_json(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        fail(f"Could not read JSON from {path}: {error}")
    if not isinstance(value, dict):
        fail(f"Expected a JSON object in {path}")
    return value


def terraform_values(path: Path) -> dict[str, Any]:
    raw = load_json(path)
    values: dict[str, Any] = {}
    for name, item in raw.items():
        if not isinstance(item, dict) or "value" not in item:
            fail(f"Terraform output {name!r} does not contain a value field")
        if item.get("sensitive") is True:
            fail(f"Terraform output {name!r} is sensitive and cannot enter the contract")
        values[name] = item["value"]
    return values


def require(values: dict[str, Any], name: str, expected_type: type) -> Any:
    if name not in values:
        fail(f"Required Terraform output is missing: {name}")
    value = values[name]
    if not isinstance(value, expected_type):
        fail(
            f"Terraform output {name!r} must be {expected_type.__name__}, "
            f"got {type(value).__name__}"
        )
    return value


def nullable_string(values: dict[str, Any], name: str) -> str | None:
    if name not in values:
        fail(f"Required Terraform output is missing: {name}")
    value = values[name]
    if value is not None and not isinstance(value, str):
        fail(f"Terraform output {name!r} must be string or null")
    return value


def build_contract(
    values: dict[str, Any],
    *,
    source_repository: str,
    source_sha: str,
    change_id: str,
) -> dict[str, Any]:
    repository_names = require(values, "ecr_repository_names", dict)
    repository_urls = require(values, "ecr_repository_urls", dict)
    ecr_repositories: dict[str, dict[str, str]] = {}
    for component in ECR_COMPONENTS:
        name = repository_names.get(component)
        url = repository_urls.get(component)
        if not isinstance(name, str) or not isinstance(url, str):
            fail(f"ECR name and URL are required for component {component!r}")
        ecr_repositories[component] = {"name": name, "url": url}

    service_account_roles = require(values, "service_account_role_arns", dict)
    if not all(
        isinstance(name, str) and isinstance(role, str)
        for name, role in service_account_roles.items()
    ):
        fail("service_account_role_arns must map string names to string ARNs")

    return {
        "contract_version": CONTRACT_VERSION,
        "producer": PRODUCER,
        "environment": "production",
        "source_repository": source_repository,
        "source_sha": source_sha,
        "change_id": change_id,
        "aws_region": require(values, "aws_region", str),
        "cluster": {
            "name": require(values, "cluster_name", str),
            "vpc_id": require(values, "vpc_id", str),
        },
        "storage": {
            "dvc_bucket": require(values, "dvc_bucket", str),
            "mlflow_artifact_bucket": require(values, "mlflow_artifact_bucket", str),
            "argo_artifact_bucket": require(values, "argo_artifact_bucket", str),
        },
        "events": {
            "dataset_queue_name": require(values, "dataset_event_queue_name", str),
            "dataset_queue_url": require(values, "dataset_event_queue_url", str),
            "dataset_queue_arn": require(values, "dataset_event_queue_arn", str),
        },
        "registry": {
            "rds_endpoint": require(values, "rds_endpoint", str),
            "rds_master_secret_arn": require(values, "rds_master_secret_arn", str),
        },
        "ecr_repositories": ecr_repositories,
        "iam_roles": {
            "service_accounts": dict(sorted(service_account_roles.items())),
            "aws_load_balancer_controller": require(
                values, "aws_load_balancer_controller_role_arn", str
            ),
            "external_dns": nullable_string(values, "external_dns_role_arn"),
        },
        "automation": {
            "model_release_publisher_secret_arn": require(
                values, "model_release_publisher_github_app_secret_arn", str
            ),
        },
        "domain": {
            "name": nullable_string(values, "public_domain_name"),
            "kserve_hostname": nullable_string(values, "kserve_hostname"),
            "zone_id": nullable_string(values, "route53_zone_id"),
            "certificate_arn": nullable_string(values, "public_certificate_arn"),
            "public_url": nullable_string(values, "kserve_public_url"),
        },
    }


def validate_contract(contract: dict[str, Any], schema: dict[str, Any]) -> None:
    Draft202012Validator.check_schema(schema)
    errors = sorted(
        Draft202012Validator(schema).iter_errors(contract),
        key=lambda error: tuple(str(part) for part in error.absolute_path),
    )
    if errors:
        details = []
        for error in errors:
            location = ".".join(str(part) for part in error.absolute_path) or "<root>"
            details.append(f"{location}: {error.message}")
        fail("Contract does not match platform-contract-v1 schema:\n- " + "\n- ".join(details))


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Build and validate the v1 platform contract from Terraform output -json."
    )
    parser.add_argument("--terraform-outputs", required=True, type=Path)
    parser.add_argument("--schema", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--source-repository", required=True)
    parser.add_argument("--source-sha", required=True)
    parser.add_argument("--change-id", required=True)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        values = terraform_values(args.terraform_outputs)
        schema = load_json(args.schema)
        contract = build_contract(
            values,
            source_repository=args.source_repository,
            source_sha=args.source_sha,
            change_id=args.change_id,
        )
        validate_contract(contract, schema)
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(
            json.dumps(contract, indent=2, sort_keys=True) + "\n", encoding="utf-8"
        )
    except ContractBuildError as error:
        print(f"error: {error}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
