from __future__ import annotations

import importlib.util
import json
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
MODULE_PATH = ROOT / "scripts" / "build_platform_contract.py"
SPEC = importlib.util.spec_from_file_location("build_platform_contract", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


def wrapped(value: object, *, sensitive: bool = False) -> dict[str, object]:
    return {"sensitive": sensitive, "type": "dynamic", "value": value}


def fixture() -> dict[str, dict[str, object]]:
    account = "123456789012"
    region = "ap-southeast-1"
    prefix = f"{account}.dkr.ecr.{region}.amazonaws.com/iris-mlops-prod"
    role = f"arn:aws:iam::{account}:role/iris-role"
    return {
        "aws_region": wrapped(region),
        "cluster_name": wrapped("iris-mlops-prod"),
        "vpc_id": wrapped("vpc-0123abcdef"),
        "dvc_bucket": wrapped("iris-prod-dvc-12345678"),
        "mlflow_artifact_bucket": wrapped("iris-prod-mlflow-12345678"),
        "argo_artifact_bucket": wrapped("iris-prod-argo-12345678"),
        "dataset_event_queue_name": wrapped("iris-prod-dataset-events"),
        "dataset_event_queue_url": wrapped(
            f"https://sqs.{region}.amazonaws.com/{account}/iris-prod-dataset-events"
        ),
        "dataset_event_queue_arn": wrapped(
            f"arn:aws:sqs:{region}:{account}:iris-prod-dataset-events"
        ),
        "rds_endpoint": wrapped("iris.example.ap-southeast-1.rds.amazonaws.com"),
        "rds_master_secret_arn": wrapped(
            f"arn:aws:secretsmanager:{region}:{account}:secret:iris-rds-AbCdEf"
        ),
        "ecr_repository_names": wrapped(
            {name: f"iris-mlops-prod/{name}" for name in MODULE.ECR_COMPONENTS}
        ),
        "ecr_repository_urls": wrapped(
            {name: f"{prefix}/{name}" for name in MODULE.ECR_COMPONENTS}
        ),
        "service_account_role_arns": wrapped(
            {
                "mlflow": role,
                "training": role,
                "argo_events": role,
                "external_secrets": role,
                "external_dns": role,
            }
        ),
        "aws_load_balancer_controller_role_arn": wrapped(role),
        "external_dns_role_arn": wrapped(role),
        "github_gitops_automation_role_arn": wrapped(role),
        "github_release_automation_publish_role_arn": wrapped(role),
        "model_release_publisher_github_app_secret_arn": wrapped(
            f"arn:aws:secretsmanager:{region}:{account}:secret:iris-intent-AbCdEf"
        ),
        "gitops_automation_github_app_secret_arn": wrapped(
            f"arn:aws:secretsmanager:{region}:{account}:secret:iris-gitops-AbCdEf"
        ),
        "public_domain_name": wrapped("example.com"),
        "kserve_hostname": wrapped("api.example.com"),
        "route53_zone_id": wrapped("Z0123456789ABC"),
        "public_certificate_arn": wrapped(
            f"arn:aws:acm:{region}:{account}:certificate/1234"
        ),
        "kserve_public_url": wrapped("https://api.example.com"),
    }


class BuildPlatformContractTest(unittest.TestCase):
    def setUp(self) -> None:
        self.schema = json.loads(
            (ROOT / "contracts" / "platform-contract-v1.schema.json").read_text()
        )

    def test_builds_schema_valid_contract(self) -> None:
        values = {name: item["value"] for name, item in fixture().items()}
        contract = MODULE.build_contract(
            values,
            source_repository="chiendz11/iris-infrastructure",
            source_sha="a" * 40,
            change_id="run-123-1",
        )

        MODULE.validate_contract(contract, self.schema)

        self.assertEqual(contract["contract_version"], "v1")
        self.assertEqual(contract["domain"]["kserve_hostname"], "api.example.com")
        self.assertIn("model_release_publisher_secret_arn", contract["automation"])
        self.assertNotIn("gitops_automation_secret_arn", contract["automation"])
        self.assertNotIn("gitops_automation", contract["iam_roles"])
        self.assertEqual(
            contract["ecr_repositories"]["inference"]["name"],
            "iris-mlops-prod/inference",
        )

    def test_rejects_sensitive_terraform_output(self) -> None:
        outputs = fixture()
        outputs["rds_master_secret_arn"] = wrapped("must-not-publish", sensitive=True)
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "outputs.json"
            path.write_text(json.dumps(outputs), encoding="utf-8")

            with self.assertRaisesRegex(MODULE.ContractBuildError, "sensitive"):
                MODULE.terraform_values(path)

    def test_rejects_missing_selected_output(self) -> None:
        values = {name: item["value"] for name, item in fixture().items()}
        del values["vpc_id"]

        with self.assertRaisesRegex(MODULE.ContractBuildError, "vpc_id"):
            MODULE.build_contract(
                values,
                source_repository="chiendz11/iris-infrastructure",
                source_sha="a" * 40,
                change_id="run-123-1",
            )

    def test_schema_rejects_additional_fields(self) -> None:
        values = {name: item["value"] for name, item in fixture().items()}
        contract = MODULE.build_contract(
            values,
            source_repository="chiendz11/iris-infrastructure",
            source_sha="a" * 40,
            change_id="run-123-1",
        )
        contract["gitops_manifest_path"] = "environments/production"

        with self.assertRaisesRegex(MODULE.ContractBuildError, "Additional properties"):
            MODULE.validate_contract(contract, self.schema)


if __name__ == "__main__":
    unittest.main()
