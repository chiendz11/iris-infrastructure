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

variable "manage_application_config" {
  description = "Read platform state and manage app-repository environments/variables after platform exists."
  type        = bool
  default     = false
}

variable "discover_existing_configuration" {
  description = "Discover/adopt existing owned configuration during trusted apply. Disable only for credential-free speculative PR plans."
  type        = bool
  default     = true
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
  description = "Full repository name receiving versioned release and platform contracts."
  type        = string
  default     = "chiendz11/iris-gitops"
}

variable "inference_publisher_app_client_id" {
  description = "Client ID of the Actions-only App dedicated to iris-inference-service."
  type        = string
  default     = ""

  validation {
    condition     = !var.manage_application_config || trimspace(var.inference_publisher_app_client_id) != ""
    error_message = "inference_publisher_app_client_id is required when application configuration is enabled."
  }
}

variable "model_registry_publisher_app_client_id" {
  description = "Client ID of the Actions-only App dedicated to iris-model-registry."
  type        = string
  default     = ""

  validation {
    condition     = !var.manage_application_config || trimspace(var.model_registry_publisher_app_client_id) != ""
    error_message = "model_registry_publisher_app_client_id is required when application configuration is enabled."
  }
}

variable "platform_contract_publisher_actor" {
  description = "Exact GitHub App bot login allowed to dispatch platform contracts (for example iris-platform-contract-publisher[bot])."
  type        = string
  default     = ""

  validation {
    condition = !var.manage_application_config || can(regex(
      "^[A-Za-z0-9](?:[A-Za-z0-9-]{0,98}[A-Za-z0-9])?\\[bot\\]$",
      var.platform_contract_publisher_actor,
    ))
    error_message = "platform_contract_publisher_actor must be an exact GitHub App bot login ending in [bot]."
  }
}

variable "inference_publisher_actor" {
  description = "Exact GitHub App bot login allowed to publish inference workload intents."
  type        = string
  default     = ""

  validation {
    condition = !var.manage_application_config || can(regex(
      "^[A-Za-z0-9](?:[A-Za-z0-9-]{0,98}[A-Za-z0-9])?\\[bot\\]$",
      var.inference_publisher_actor,
    ))
    error_message = "inference_publisher_actor must be an exact GitHub App bot login ending in [bot]."
  }
}

variable "model_registry_publisher_actor" {
  description = "Exact GitHub App bot login allowed to publish model-registry workload intents."
  type        = string
  default     = ""

  validation {
    condition = !var.manage_application_config || can(regex(
      "^[A-Za-z0-9](?:[A-Za-z0-9-]{0,98}[A-Za-z0-9])?\\[bot\\]$",
      var.model_registry_publisher_actor,
    ))
    error_message = "model_registry_publisher_actor must be an exact GitHub App bot login ending in [bot]."
  }
}

variable "model_release_publisher_actor" {
  description = "Exact GitHub App bot login allowed to publish in-cluster model lifecycle intents."
  type        = string
  default     = ""

  validation {
    condition = !var.manage_application_config || can(regex(
      "^[A-Za-z0-9](?:[A-Za-z0-9-]{0,98}[A-Za-z0-9])?\\[bot\\]$",
      var.model_release_publisher_actor,
    ))
    error_message = "model_release_publisher_actor must be an exact GitHub App bot login ending in [bot]."
  }
}
