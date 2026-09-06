variable "github_owner" {
  description = "GitHub user or organization that owns the five Iris repositories."
  type        = string
  default     = "chiendz11"

  validation {
    condition     = can(regex("^[A-Za-z0-9](?:[A-Za-z0-9-]{0,37}[A-Za-z0-9])?$", var.github_owner))
    error_message = "github_owner must be a valid GitHub user or organization login."
  }
}

variable "github_actions_integration_id" {
  description = "GitHub Actions App integration ID used to bind required checks to their real producer."
  type        = number
  default     = 15368
}

variable "repository_rulesets" {
  description = "Authoritative required checks for every repository protected by Terraform."
  type = map(object({
    required_checks = set(string)
  }))

  default = {
    iris-infrastructure = {
      required_checks = ["pr-gate"]
    }
    iris-gitops = {
      required_checks = ["validate"]
    }
    iris-data-pipeline = {
      required_checks = ["ci-gate"]
    }
    iris-model-registry = {
      required_checks = ["ci-gate"]
    }
    iris-inference-service = {
      required_checks = ["ci-gate"]
    }
  }

  validation {
    condition = alltrue([
      for repository, settings in var.repository_rulesets :
      repository != "" && length(settings.required_checks) > 0 && alltrue([
        for check in settings.required_checks : trimspace(check) != ""
      ])
    ])
    error_message = "Each governed repository must have at least one non-empty required check."
  }
}

# These IDs are public GitHub metadata for the rulesets that already exist.
# Importing them prevents Terraform from creating a second, layered ruleset.
variable "existing_ruleset_ids" {
  description = "Existing protect-main ruleset IDs used for the one-time declarative import."
  type        = map(number)

  default = {
    iris-infrastructure    = 21312051
    iris-gitops            = 21312006
    iris-data-pipeline     = 21312047
    iris-model-registry    = 21312049
    iris-inference-service = 21312050
  }
}

check "every_ruleset_has_an_import_identity" {
  assert {
    condition     = length(setsubtract(toset(keys(var.existing_ruleset_ids)), toset(keys(var.repository_rulesets)))) == 0
    error_message = "Every existing_ruleset_ids key must also exist in repository_rulesets."
  }
}
