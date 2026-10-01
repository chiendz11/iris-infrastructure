terraform {
  required_version = ">= 1.10.0"

  backend "s3" {
    key          = "infrastructure/github-config.tfstate"
    use_lockfile = true
    encrypt      = true
  }

  required_providers {
    github = {
      source  = "integrations/github"
      version = "~> 6.13"
    }
  }
}

# CI exports only a short-lived GitHub App installation token as GITHUB_TOKEN.
# A credential is deliberately not accepted as an input variable, which keeps
# it out of plans, tfvars and Terraform state.
provider "github" {
  owner = var.github_owner
}
