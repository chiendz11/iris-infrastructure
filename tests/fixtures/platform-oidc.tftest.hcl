variables {
  state_bucket_name = "iris-offline-test"
  state_kms_key_arn = "arn:aws:kms:ap-southeast-1:123456789012:key/00000000-0000-0000-0000-000000000000"
}

run "verified_prefixes_match_repository_identities" {
  command = plan
  assert {
    condition = var.github_oidc_subject_prefixes == tomap({
      "chiendz11/iris-data-pipeline"     = "repo:chiendz11@169627609/iris-data-pipeline@1340834360"
      "chiendz11/iris-model-registry"    = "repo:chiendz11@169627609/iris-model-registry@1340834550"
      "chiendz11/iris-inference-service" = "repo:chiendz11@169627609/iris-inference-service@1340834663"
      "chiendz11/iris-gitops"            = "repo:chiendz11@169627609/iris-gitops@1342006443"
    })
    error_message = "All four verified repository identities must remain pinned."
  }
}

run "reject_missing_prefix_mapping" {
  command = plan
  variables {
    github_oidc_subject_prefixes = {}
  }
  expect_failures = [var.github_oidc_subject_prefixes]
}

run "reject_wildcard_prefix" {
  command = plan
  variables {
    github_oidc_subject_prefixes = {
      "chiendz11/iris-data-pipeline"     = "repo:chiendz11/*"
      "chiendz11/iris-model-registry"    = "repo:chiendz11/iris-model-registry"
      "chiendz11/iris-inference-service" = "repo:chiendz11/iris-inference-service"
      "chiendz11/iris-gitops"            = "repo:chiendz11/iris-gitops"
    }
  }
  expect_failures = [var.github_oidc_subject_prefixes]
}

run "reject_mismatched_repository" {
  command = plan
  variables {
    gitops_repository = "other-owner/iris-gitops"
  }
  expect_failures = [var.github_oidc_subject_prefixes]
}

run "reject_context_in_prefix" {
  command = plan
  variables {
    github_oidc_subject_prefixes = {
      "chiendz11/iris-data-pipeline"     = "repo:chiendz11/iris-data-pipeline"
      "chiendz11/iris-model-registry"    = "repo:chiendz11/iris-model-registry"
      "chiendz11/iris-inference-service" = "repo:chiendz11/iris-inference-service"
      "chiendz11/iris-gitops"            = "repo:chiendz11/iris-gitops:ref:refs/heads/main"
    }
  }
  expect_failures = [var.github_oidc_subject_prefixes]
}
