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

variable "vpc_cidr" {
  type    = string
  default = "10.42.0.0/16"
}

variable "az_count" {
  description = "Number of Availability Zones used by VPC, EKS and RDS subnet groups. EKS requires at least two."
  type        = number
  default     = 2

  validation {
    condition     = var.az_count >= 2 && var.az_count <= 3
    error_message = "az_count must be either 2 or 3."
  }
}

variable "enable_nat_gateway" {
  description = "Keep internet egress for Argo CD, public Helm repositories and public container registries."
  type        = bool
  default     = true
}

variable "single_nat_gateway" {
  description = "Use one shared NAT gateway to reduce capstone cost. Set false for one NAT gateway per AZ."
  type        = bool
  default     = true
}

variable "enable_interface_vpc_endpoints" {
  description = "Create charged interface endpoints for AWS APIs. S3 gateway endpoint is always created."
  type        = bool
  default     = false
}

variable "kubernetes_version" {
  type    = string
  default = "1.33"
}

variable "node_instance_types" {
  type    = list(string)
  default = ["t3.medium"]
}

variable "node_min_size" {
  type    = number
  default = 2
}

variable "node_max_size" {
  type    = number
  default = 3
}

variable "node_desired_size" {
  type    = number
  default = 2
}

variable "db_instance_class" {
  type    = string
  default = "db.t4g.micro"
}

variable "db_multi_az" {
  description = "Run the MLflow PostgreSQL instance with a synchronous standby in another AZ."
  type        = bool
  default     = true
}

variable "db_name" {
  type    = string
  default = "mlflow"
}

variable "db_username" {
  type    = string
  default = "mlflow_admin"
}

variable "admin_role_arns" {
  description = "IAM roles that receive EKS cluster-admin access."
  type        = list(string)
  default     = []
}

variable "github_repositories" {
  description = "Repositories allowed to assume the shared build/publish role."
  type        = list(string)
  default = [
    "chiendz11/iris-data-pipeline",
    "chiendz11/iris-model-registry",
    "chiendz11/iris-inference-service"
  ]
}

variable "enable_public_domain" {
  description = "Create one shared ACM certificate for the apex/wildcard domain and ExternalDNS permissions."
  type        = bool
  default     = false
}

variable "route53_zone_id" {
  description = "Existing public Route53 hosted zone ID for the KServe hostname."
  type        = string
  default     = null
  nullable    = true
}

variable "public_domain_name" {
  description = "Apex public domain covered together with its one-level wildcard, for example example.com."
  type        = string
  default     = null
  nullable    = true
}

variable "kserve_subdomain" {
  description = "Flat subdomain used by the public inference API."
  type        = string
  default     = "api"

  validation {
    condition     = can(regex("^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$", var.kserve_subdomain))
    error_message = "kserve_subdomain must be a single valid DNS label such as api or iris-api."
  }
}
