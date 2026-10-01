# Native provider reads only: no gh script, credentials in variables, or
# unconditional import IDs. A successful empty list means create, not import.
data "github_rest_api" "repository_rulesets" {
  for_each = var.discover_existing_rulesets ? var.repository_rulesets : {}
  endpoint = "repos/${var.github_owner}/${each.key}/rulesets?includes_parents=false&per_page=100"

  lifecycle {
    postcondition {
      condition     = self.code == 200
      error_message = "Cannot discover rulesets for ${each.key}: require HTTP 200. A missing repository, denied access or API failure is NOT an empty ruleset list."
    }
    postcondition {
      condition     = can(concat(jsondecode(self.body), []))
      error_message = "Ruleset discovery for ${each.key} must return a JSON array."
    }
    postcondition {
      condition = try(alltrue([
        for rule in jsondecode(self.body) :
        rule.id > 0 && rule.id == floor(rule.id) &&
        length(rule.name) > 0 && length(rule.source_type) > 0 && length(rule.source) > 0
      ]), false)
      error_message = "Incomplete ruleset metadata for ${each.key}; do not mistake an unidentifiable object for an absent ruleset."
    }
    postcondition {
      condition     = !can(regex("rel=[^,]*next", lower(self.headers)))
      error_message = "Ruleset discovery for ${each.key} is paginated. Stop rather than adopt/create from an incomplete list; extend discovery before retrying."
    }
    postcondition {
      condition = length(try([
        for rule in jsondecode(self.body) : rule
        if try(rule.name == "protect-main" && rule.source_type == "Repository" && lower(rule.source) == lower("${var.github_owner}/${each.key}"), false)
      ], [])) <= 1
      error_message = "Multiple repository-owned protect-main rulesets found for ${each.key}; resolve the ambiguity explicitly before applying."
    }
  }
}

locals {
  matching_rulesets = {
    for repository, result in data.github_rest_api.repository_rulesets : repository => try([
      for rule in jsondecode(result.body) : rule
      if try(rule.name == "protect-main" && rule.source_type == "Repository" && lower(rule.source) == lower("${var.github_owner}/${repository}"), false)
    ], [])
  }
  discovered_ruleset_ids = {
    for repository, matches in local.matching_rulesets : repository => matches[0].id
    if length(matches) == 1
  }
}

# The listing does not reliably contain the target. Verify the individual
# object too: never adopt a tag/push or organization ruleset as branch policy.
data "github_rest_api" "owned_ruleset" {
  for_each = local.discovered_ruleset_ids
  endpoint = "repos/${var.github_owner}/${each.key}/rulesets/${each.value}?includes_parents=false"

  lifecycle {
    postcondition {
      condition = self.code == 200 && try(
        jsondecode(self.body).id == each.value &&
        jsondecode(self.body).name == "protect-main" &&
        jsondecode(self.body).target == "branch" &&
        jsondecode(self.body).source_type == "Repository" &&
        lower(jsondecode(self.body).source) == lower("${var.github_owner}/${each.key}"),
        false,
      )
      error_message = "Existing protect-main for ${each.key} must be the verified repository-owned branch ruleset. No automatic adoption of another target or source."
    }
  }
}

locals {
  # Depending on the detail response ensures its postconditions run before import.
  import_ruleset_ids = {
    for repository, result in data.github_rest_api.owned_ruleset : repository => jsondecode(result.body).id
  }
}

import {
  for_each = local.import_ruleset_ids

  to = github_repository_ruleset.main[each.key]
  id = "${each.key}:${each.value}"
}
