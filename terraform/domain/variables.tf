variable "aws_region" {
  type    = string
  default = "ap-southeast-1"
}

variable "project_name" {
  type    = string
  default = "iris-mlops"
}

variable "environment" {
  type    = string
  default = "prod"
}

variable "enable_public_domain" {
  description = "Create and own the public Route53 hosted zone."
  type        = bool
  default     = false
}

variable "domain_name" {
  description = "Apex domain delegated to Route53, for example example.com."
  type        = string
  default     = null
  nullable    = true

  validation {
    condition = var.domain_name == null || can(regex(
      "^(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\\.)+[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$",
      var.domain_name
    ))
    error_message = "domain_name must be a lowercase DNS name without a trailing dot, such as example.com."
  }
}

variable "domain_delegated" {
  description = "Internal CI phase flag; the certificate job sets it true only after DNS verification passes."
  type        = bool
  default     = false
}

check "public_domain_name" {
  assert {
    condition     = !var.enable_public_domain || var.domain_name != null
    error_message = "domain_name is required when enable_public_domain is true."
  }
}
