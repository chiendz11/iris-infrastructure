terraform {
  required_version = ">= 1.10.0"

  backend "s3" {
    key          = "infrastructure/github-governance.tfstate"
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

# Authentication is intentionally supplied through the GITHUB_TOKEN environment
# variable. No GitHub credential is accepted as a Terraform variable or written
# to tfvars/state.
provider "github" {
  owner = var.github_owner
}
