variable "aws_region" {
  description = "AWS region that contains the Terraform state bucket."
  type        = string
  default     = "ap-southeast-1"
}

variable "state_bucket_name" {
  description = "S3 bucket containing the foundation and platform remote states."
  type        = string
}

variable "state_kms_key_arn" {
  description = "KMS key used to encrypt every Terraform state object."
  type        = string
}

variable "github_owner" {
  description = "GitHub account that owns the Iris repositories."
  type        = string
  default     = "chiendz11"

  validation {
    condition     = can(regex("^[A-Za-z0-9](?:[A-Za-z0-9-]{0,37}[A-Za-z0-9])?$", var.github_owner))
    error_message = "github_owner must be a valid GitHub login."
  }
}

variable "infrastructure_repository" {
  description = "Repository that runs the infrastructure control-plane workflows."
  type        = string
  default     = "iris-infrastructure"
}

variable "application_repositories" {
  description = "Application repositories whose production deployment configuration is managed here."
  type        = set(string)
  default = [
    "iris-data-pipeline",
    "iris-model-registry",
    "iris-inference-service",
  ]
}

variable "production_environment" {
  description = "Protected GitHub Environment used by production mutation jobs."
  type        = string
  default     = "prod"
}

variable "production_reviewer_usernames" {
  description = "Independent GitHub collaborators allowed to approve application production deployments."
  type        = set(string)
  default     = []

  validation {
    condition = !var.manage_application_config || (
      length(var.production_reviewer_usernames) > 0 &&
      length(var.production_reviewer_usernames) <= 6 &&
      alltrue([
        for username in var.production_reviewer_usernames :
        can(regex("^[A-Za-z0-9](?:[A-Za-z0-9-]{0,37}[A-Za-z0-9])?$", username)) &&
        lower(trimspace(username)) != lower(var.github_owner)
      ])
    )
    error_message = "When manage_application_config=true, provide at least one reviewer other than github_owner."
  }
}

variable "manage_application_config" {
  description = "Read platform state and manage app-repository environments/variables after platform exists."
  type        = bool
  default     = false
}

variable "enable_public_domain" {
  description = "Whether the domain and public edge stacks are enabled."
  type        = bool
  default     = false
}

variable "public_domain_name" {
  description = "Apex public domain. Required when enable_public_domain is true."
  type        = string
  default     = ""

  validation {
    condition     = !var.enable_public_domain || trimspace(var.public_domain_name) != ""
    error_message = "public_domain_name must be set when enable_public_domain=true."
  }
}

variable "admin_role_arns" {
  description = "IAM principals granted EKS administrator access."
  type        = list(string)
  default     = []
}

variable "gitops_repository" {
  description = "Full repository name receiving immutable image and infrastructure-output pull requests."
  type        = string
  default     = "chiendz11/iris-gitops"
}

variable "gitops_app_client_id" {
  description = "Non-secret client ID of the least-privilege GitOps pull-request GitHub App."
  type        = string
  default     = ""

  validation {
    condition     = !var.manage_application_config || trimspace(var.gitops_app_client_id) != ""
    error_message = "gitops_app_client_id is required when application configuration is enabled."
  }
}
