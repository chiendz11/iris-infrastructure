#!/usr/bin/env python3
"""One path-to-root policy for PR plans and production orchestration.

Pure classification is independently testable; no AWS/GitHub credentials.
Decisions about completed stages stay visible in the orchestrator's needs/if.
"""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import re
import subprocess

ROOTS = ("foundation", "governance", "github_config", "domain", "platform")
SCOPES = ("all", "foundation", "governance", "github-config", "domain", "platform", "handoff")
PREFIXES = {
    "terraform/bootstrap/": "foundation",
    "terraform/github-governance/": "governance",
    "terraform/github-config/": "github_config",
    "terraform/domain/": "domain",
    "terraform/platform/": "platform",
}
FILES = {
    "environments/production.tfvars": "platform",
    "contracts/platform-contract-v1.schema.json": "platform",
    "requirements-contract.txt": "platform",
    "scripts/build_platform_contract.py": "platform",
    "scripts/require-domain-ready.sh": "platform",
    "scripts/detect-domain-delegation.sh": "domain",
    "scripts/wait-for-dns-delegation.sh": "domain",
    "scripts/migrate-rulesets.sh": "governance",
    ".github/workflows/terraform-domain-certificate.yml": "domain",
    ".github/workflows/reusable-certificate.yml": "domain",
    ".github/workflows/reusable-platform-handoff.yml": "platform",
    **{f".github/workflows/reusable-{root.replace('_', '-')}.yml": root for root in ROOTS},
}
SHARED = {
    ".github/workflows/production-infra.yml",
    "scripts/plan_production.py",
    "scripts/assert-current-main.sh",
}


def classify(paths: list[str]) -> dict[str, bool]:
    result = dict.fromkeys(ROOTS, False)
    for path in paths:
        if path in SHARED:
            return dict.fromkeys(ROOTS, True)
        if path in FILES:
            result[FILES[path]] = True
        for prefix, root in PREFIXES.items():
            if path.startswith(prefix):
                result[root] = True
    return result


def select(paths: list[str], *, mode: str, scope: str = "") -> dict[str, bool]:
    if mode not in {"pr", "push", "manual"}:
        raise ValueError("Unknown classification mode")
    if mode == "manual":
        if scope not in SCOPES:
            raise ValueError("Unknown production scope")
        result = {root: scope == "all" or root == scope.replace("-", "_") for root in ROOTS}
    else:
        result = classify(paths)
    result["handoff"] = mode == "manual" and scope == "handoff"
    if mode != "pr" and result["foundation"]:
        result["github_config"] = True
    return result


def changed_paths(base: str, head: str) -> list[str]:
    for value in (base, head):
        if not re.fullmatch(r"[0-9a-f]{40}", value):
            raise ValueError("Expected full Git SHA for base/head")
    if base == "0" * 40:
        args = ["git", "ls-tree", "-r", "--name-only", "-z", head]
    else:
        args = ["git", "diff", "--no-renames", "--name-only", "-z", base, head, "--"]
    return subprocess.check_output(args, text=True).rstrip("\0").split("\0")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--mode", choices=("pr", "push", "manual"), required=True)
    parser.add_argument("--scope", default="")
    parser.add_argument("--base", default="")
    parser.add_argument("--head", default="")
    args = parser.parse_args()
    paths = [] if args.mode == "manual" else changed_paths(args.base, args.head)
    result = select(paths, mode=args.mode, scope=args.scope)
    if output := os.getenv("GITHUB_OUTPUT"):
        with Path(output).open("a") as stream:
            for key, value in result.items():
                stream.write(f"{key}={str(value).lower()}\n")
    if summary := os.getenv("GITHUB_STEP_SUMMARY"):
        with Path(summary).open("a") as stream:
            stream.write("## Selected infrastructure stages\n\n")
            for key, value in result.items():
                stream.write(f"- {key}: {str(value).lower()}\n")
            stream.write("\nUnchanged prerequisites are reused, not recreated. See the needs graph.\n")
    print(json.dumps(result, sort_keys=True))


if __name__ == "__main__":
    main()
