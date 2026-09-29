# Protected apply discovers existing objects. main.tf creates missing ones.
# API/authentication errors fail rather than being mistaken for absence.
locals {
  discovery_repositories = var.discover_existing_configuration ? setunion(
    toset([var.infrastructure_repository]),
    var.manage_application_config ? var.application_repositories : toset([]),
    var.manage_application_config ? toset([local.gitops_repository_name]) : toset([]),
  ) : toset([])
}

data "github_repository_environments" "existing" {
  for_each   = local.discovery_repositories
  repository = each.value

  lifecycle {
    postcondition {
      condition = each.value != var.infrastructure_repository || contains(
        [for environment in self.environments : environment.name], var.production_environment,
      )
      error_message = "The infrastructure prod root-of-trust Environment must be bootstrapped by the owner with configure-github.sh; this root must not create its own approval gate."
    }
  }
}

locals {
  repositories_with_prod = toset([
    for repository, result in data.github_repository_environments.existing : repository
    if contains([for environment in result.environments : environment.name], var.production_environment)
  ])
  existing_application_environments = setintersection(
    local.repositories_with_prod,
    var.manage_application_config ? var.application_repositories : toset([]),
  )
}

data "github_actions_variables" "existing" {
  for_each = local.discovery_repositories
  name     = each.value
}

# Never query variables under an Environment that does not yet exist.
data "github_actions_environment_variables" "existing" {
  for_each    = local.repositories_with_prod
  name        = each.value
  environment = var.production_environment
}

locals {
  existing_repository_variable_names = {
    for repository, result in data.github_actions_variables.existing :
    repository => toset([for variable in coalesce(result.variables, []) : variable.name])
  }
  existing_environment_variable_names = {
    for repository, result in data.github_actions_environment_variables.existing :
    repository => toset([for variable in coalesce(result.variables, []) : variable.name])
  }
  existing_infrastructure_variables = setintersection(
    toset(keys(local.infrastructure_variables)),
    lookup(local.existing_repository_variable_names, var.infrastructure_repository, toset([])),
  )
  existing_infrastructure_environment_variables = setintersection(
    toset(keys(local.infrastructure_variables)),
    lookup(local.existing_environment_variable_names, var.infrastructure_repository, toset([])),
  )
  existing_application_variables = {
    for key, setting in local.flattened_application_variables : key => setting
    if contains(lookup(local.existing_environment_variable_names, setting.repository, toset([])), setting.name)
  }
  existing_gitops_variables = setintersection(
    toset(keys(local.gitops_repository_variables)),
    lookup(local.existing_repository_variable_names, local.gitops_repository_name, toset([])),
  )
}

import {
  for_each = local.existing_application_environments
  to       = github_repository_environment.application_prod[each.value]
  id       = "${each.value}:${var.production_environment}"
}

import {
  for_each = local.existing_infrastructure_variables
  to       = github_actions_variable.infrastructure[each.value]
  id       = "${var.infrastructure_repository}:${each.value}"
}

import {
  for_each = local.existing_infrastructure_environment_variables
  to       = github_actions_environment_variable.infrastructure_prod[each.value]
  id       = "${var.infrastructure_repository}:${var.production_environment}:${each.value}"
}

import {
  for_each = local.existing_application_variables
  to       = github_actions_environment_variable.application_prod[each.key]
  id       = "${each.value.repository}:${var.production_environment}:${each.value.name}"
}

import {
  for_each = local.existing_gitops_variables
  to       = github_actions_variable.gitops_automation[each.value]
  id       = "${local.gitops_repository_name}:${each.value}"
}
