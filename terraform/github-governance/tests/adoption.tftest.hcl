# No real API reads, writes, token or AWS state. Test discovery and guards with
# the installed GitHub provider schema and mocked responses only.
mock_provider "github" {
  mock_data "github_rest_api" {
    defaults = {
      code    = 200
      status  = "200 OK"
      headers = "{}"
      body    = "[]"
    }
  }
}

run "fresh_repositories_create_all_rulesets" {
  command = plan
  assert {
    condition     = length(local.import_ruleset_ids) == 0 && length(github_repository_ruleset.main) == 5
    error_message = "Successful empty lists must create all five rulesets without importing stale IDs."
  }
}

run "mixed_repositories_adopt_only_existing_owned_ruleset" {
  command = plan
  override_data {
    target = data.github_rest_api.repository_rulesets["iris-gitops"]
    values = {
      code    = 200
      headers = "{}"
      body = jsonencode([
        { id = 42, name = "protect-main", source_type = "Repository", source = "chiendz11/iris-gitops" },
        { id = 43, name = "protect-tags", source_type = "Repository", source = "chiendz11/iris-gitops" },
        { id = 44, name = "protect-main", source_type = "Organization", source = "chiendz11" },
      ])
    }
  }
  override_data {
    target = data.github_rest_api.owned_ruleset["iris-gitops"]
    values = {
      code    = 200
      headers = "{}"
      body    = jsonencode({ id = 42, name = "protect-main", target = "branch", source_type = "Repository", source = "chiendz11/iris-gitops" })
    }
  }
  override_resource {
    target = github_repository_ruleset.main["iris-gitops"]
    values = { id = "iris-gitops:42", repository = "iris-gitops", name = "protect-main", ruleset_id = 42 }
  }
  assert {
    condition     = local.import_ruleset_ids == { "iris-gitops" = 42 } && length(github_repository_ruleset.main) == 5
    error_message = "Adopt only the matching repository policy, leave other rulesets alone, and still create missing policies."
  }
}

run "missing_repository_is_not_an_empty_list" {
  command = plan
  override_data {
    target = data.github_rest_api.repository_rulesets["iris-gitops"]
    values = { code = 404, body = "[]", headers = "{}" }
  }
  expect_failures = [data.github_rest_api.repository_rulesets["iris-gitops"]]
}

run "denied_access_is_not_an_empty_list" {
  command = plan
  override_data {
    target = data.github_rest_api.repository_rulesets["iris-gitops"]
    values = { code = 403, body = "[]", headers = "{}" }
  }
  expect_failures = [data.github_rest_api.repository_rulesets["iris-gitops"]]
}

run "api_outage_is_not_an_empty_list" {
  command = plan
  override_data {
    target = data.github_rest_api.repository_rulesets["iris-gitops"]
    values = { code = 500, body = "[]", headers = "{}" }
  }
  expect_failures = [data.github_rest_api.repository_rulesets["iris-gitops"]]
}

run "duplicate_names_require_operator_resolution" {
  command = plan
  override_data {
    target = data.github_rest_api.repository_rulesets["iris-gitops"]
    values = {
      code    = 200
      headers = "{}"
      body = jsonencode([
        { id = 42, name = "protect-main", source_type = "Repository", source = "chiendz11/iris-gitops" },
        { id = 43, name = "protect-main", source_type = "Repository", source = "chiendz11/iris-gitops" },
      ])
    }
  }
  expect_failures = [data.github_rest_api.repository_rulesets["iris-gitops"]]
}

run "incomplete_pagination_fails_closed" {
  command = plan
  override_data {
    target = data.github_rest_api.repository_rulesets["iris-gitops"]
    values = { code = 200, body = "[]", headers = jsonencode({ Link = ["<https://api.github.com/repos/chiendz11/iris-gitops/rulesets?page=2>; rel=\"next\""] }) }
  }
  expect_failures = [data.github_rest_api.repository_rulesets["iris-gitops"]]
}

run "malformed_response_fails_closed" {
  command = plan
  override_data {
    target = data.github_rest_api.repository_rulesets["iris-gitops"]
    values = { code = 200, headers = "{}", body = "{\"message\":\"unexpected response\"}" }
  }
  expect_failures = [data.github_rest_api.repository_rulesets["iris-gitops"]]
}

run "incomplete_metadata_fails_closed" {
  command = plan
  override_data {
    target = data.github_rest_api.repository_rulesets["iris-gitops"]
    values = { code = 200, headers = "{}", body = "[{\"id\":42,\"name\":\"protect-main\"}]" }
  }
  expect_failures = [data.github_rest_api.repository_rulesets["iris-gitops"]]
}

run "wrong_target_is_never_adopted_as_branch_policy" {
  command = plan
  override_data {
    target = data.github_rest_api.repository_rulesets["iris-gitops"]
    values = { code = 200, headers = "{}", body = jsonencode([{ id = 42, name = "protect-main", source_type = "Repository", source = "chiendz11/iris-gitops" }]) }
  }
  override_data {
    target = data.github_rest_api.owned_ruleset["iris-gitops"]
    values = { code = 200, headers = "{}", body = jsonencode({ id = 42, name = "protect-main", target = "tag", source_type = "Repository", source = "chiendz11/iris-gitops" }) }
  }
  expect_failures = [data.github_rest_api.owned_ruleset["iris-gitops"]]
}

run "explicit_stale_identity_fails_closed" {
  command = plan
  variables {
    existing_ruleset_ids = { iris-gitops = 999 }
  }
  expect_failures = [github_repository_ruleset.main["iris-gitops"]]
}

run "unknown_repository_identity_is_invalid" {
  command = plan
  variables {
    existing_ruleset_ids = { not-managed = 999 }
  }
  expect_failures = [var.existing_ruleset_ids]
}

run "pr_plan_never_discovers_or_imports" {
  command = plan
  variables {
    discover_existing_rulesets = false
  }
  assert {
    condition     = length(data.github_rest_api.repository_rulesets) == 0 && length(data.github_rest_api.owned_ruleset) == 0 && length(local.import_ruleset_ids) == 0
    error_message = "PR plans must not make live discovery/import calls or require privileged App credentials."
  }
}
