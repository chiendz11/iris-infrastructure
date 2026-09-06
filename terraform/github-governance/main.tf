resource "github_repository_ruleset" "main" {
  for_each = var.repository_rulesets

  name        = "protect-main"
  repository  = each.key
  target      = "branch"
  enforcement = "active"

  conditions {
    ref_name {
      include = ["~DEFAULT_BRANCH"]
      exclude = []
    }
  }

  rules {
    deletion                = true
    non_fast_forward        = true
    required_linear_history = true

    pull_request {
      allowed_merge_methods             = ["squash", "rebase"]
      dismiss_stale_reviews_on_push     = true
      require_code_owner_review         = true
      require_last_push_approval        = true
      required_approving_review_count   = 1
      required_review_thread_resolution = true
    }

    required_status_checks {
      strict_required_status_checks_policy = true
      do_not_enforce_on_create             = false

      dynamic "required_check" {
        for_each = each.value.required_checks
        content {
          context        = required_check.value
          integration_id = var.github_actions_integration_id
        }
      }
    }
  }

  # Removing a repository from the map must not silently remove its protection.
  # Retiring a repository therefore requires an explicit two-step break-glass change.
  lifecycle {
    prevent_destroy = true
  }
}
