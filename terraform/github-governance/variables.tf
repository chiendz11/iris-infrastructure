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

variable "discover_existing_rulesets" {
  description = "Read and verify repository-owned protect-main rulesets before import/create. Disable only for speculative PR plans without privileged credentials."
  type        = bool
  default     = true
}

variable "existing_ruleset_ids" {
  description = "Optional expected IDs for migration assertions, NOT unconditional imports. Protected plans verify these against discovery; normally leave empty."
  type        = map(number)
  default     = {}

  validation {
    condition     = alltrue([for id in values(var.existing_ruleset_ids) : id > 0 && id == floor(id)])
    error_message = "Expected ruleset IDs must be positive integers."
  }
  validation {
    condition     = length(setsubtract(toset(keys(var.existing_ruleset_ids)), toset(keys(var.repository_rulesets)))) == 0
    error_message = "Every existing_ruleset_ids key must also exist in repository_rulesets."
  }
}
