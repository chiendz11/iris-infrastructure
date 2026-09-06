output "repository_ruleset_ids" {
  description = "Ruleset IDs managed by this state, keyed by repository name."
  value = {
    for repository, ruleset in github_repository_ruleset.main :
    repository => ruleset.ruleset_id
  }
}

output "required_status_checks" {
  description = "Authoritative required check contexts for each repository."
  value = {
    for repository, settings in var.repository_rulesets :
    repository => sort(tolist(settings.required_checks))
  }
}
