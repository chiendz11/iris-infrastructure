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
