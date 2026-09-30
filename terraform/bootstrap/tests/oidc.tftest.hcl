# No real AWS calls or backend state: exercise configured subjects and guards.
mock_provider "aws" {}

variables {
  state_bucket_name = "iris-oidc-offline-test"
}

run "immutable_subjects_keep_plan_and_apply_separate" {
  command = plan
  assert {
    condition = toset(flatten([
      for statement in data.aws_iam_policy_document.terraform_plan_trust.statement : [
        for condition in statement.condition : tolist(condition.values)
        if condition.variable == "token.actions.githubusercontent.com:sub"
      ]
    ])) == toset(["repo:chiendz11@169627609/iris-infrastructure@1344926953:pull_request"])
    error_message = "Plan roles must trust only the exact immutable repository PR subject."
  }
  assert {
    condition = toset(flatten([
      for statement in data.aws_iam_policy_document.terraform_apply_trust.statement : [
        for condition in statement.condition : tolist(condition.values)
        if condition.variable == "token.actions.githubusercontent.com:sub"
      ]
    ])) == toset(["repo:chiendz11@169627609/iris-infrastructure@1344926953:environment:prod"])
    error_message = "Apply roles must remain scoped to prod, never PRs or arbitrary refs."
  }
}

run "reject_wildcard_prefix" {
  command = plan
  variables {
    github_oidc_subject_prefix = "repo:chiendz11/*"
  }
  expect_failures = [var.github_oidc_subject_prefix]
}

run "reject_other_repository_prefix" {
  command = plan
  variables {
    github_oidc_subject_prefix = "repo:chiendz11@169627609/another-repo@123"
  }
  expect_failures = [var.github_oidc_subject_prefix]
}

run "reject_context_in_prefix" {
  command = plan
  variables {
    github_oidc_subject_prefix = "repo:chiendz11@169627609/iris-infrastructure@1344926953:pull_request"
  }
  expect_failures = [var.github_oidc_subject_prefix]
}
