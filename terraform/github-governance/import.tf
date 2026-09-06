# All five rulesets pre-date this Terraform root. Import blocks make the first
# apply adopt and update them instead of creating a second ruleset layer.
import {
  for_each = var.existing_ruleset_ids

  to = github_repository_ruleset.main[each.key]
  id = "${each.key}:${each.value}"
}
