variable "aws_region" {
  description = "AWS region for the Terraform state bucket."
  type        = string
  default     = "ap-southeast-1"
}

variable "project_name" {
  description = "Prefix shared by all platform resources."
  type        = string
  default     = "iris-mlops"
}

variable "state_bucket_name" {
  description = "Globally unique S3 bucket name used by the platform backend."
  type        = string
}

variable "github_repository" {
  description = "GitHub repository allowed to run Terraform automation."
  type        = string
  default     = "chiendz11/iris-infrastructure"
}

variable "github_environment" {
  description = "Protected GitHub Environment embedded in OIDC trust subjects."
  type        = string
  default     = "prod"
}

variable "github_oidc_subject_prefix" {
  description = "Exact sub_claim_prefix returned by the repository OIDC API; names alone are not valid for immutable subjects."
  type        = string
  default     = "repo:chiendz11@169627609/iris-infrastructure@1344926953"

  validation {
    condition = (
      can(regex("^repo:[A-Za-z0-9_.-]+(@[0-9]+)?/[A-Za-z0-9_.-]+(@[0-9]+)?$", var.github_oidc_subject_prefix)) &&
      replace(var.github_oidc_subject_prefix, "/@[0-9]+/", "") == "repo:${var.github_repository}"
    )
    error_message = "Set the exact GitHub OIDC subject prefix for github_repository, without wildcards or a context suffix."
  }
}
