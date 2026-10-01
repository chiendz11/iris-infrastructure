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

variable "state_bucket_name" {
  description = "Bootstrap S3 bucket containing bootstrap and domain remote state."
  type        = string
  default     = null
  nullable    = true
}

variable "state_kms_key_arn" {
  description = "KMS key used to encrypt bootstrap and domain remote state."
  type        = string
  default     = null
  nullable    = true
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
  default = "1.34"
}

variable "ebs_csi_addon_version" {
  description = "Exact EKS build to pin after checking regional compatibility. Null selects AWS's default compatible version (not most_recent)."
  type        = string
  default     = null

  validation {
    condition     = var.ebs_csi_addon_version == null || can(regex("^v[0-9]+\\.[0-9]+\\.[0-9]+-eksbuild\\.[0-9]+$", var.ebs_csi_addon_version))
    error_message = "Use a compatible EKS add-on version such as vX.Y.Z-eksbuild.N, or null."
  }
}

variable "node_instance_types" {
  type    = list(string)
  default = ["t3.medium"]
}

variable "node_min_size" {
  type    = number
  default = 3
}

variable "node_max_size" {
  type    = number
  default = 4
}

variable "node_desired_size" {
  type    = number
  default = 3
}

check "argocd_ha_node_capacity" {
  assert {
    condition = (
      var.node_min_size >= 3 &&
      var.node_desired_size >= 3 &&
      var.node_max_size >= var.node_desired_size
    )
    error_message = "Argo CD Redis HA requires at least three schedulable worker nodes."
  }
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

variable "additional_external_secret_arns" {
  description = "Optional Secrets Manager ARNs that External Secrets may read, for example Argo CD SSO or repository credentials. Secret values never pass through Terraform."
  type        = list(string)
  default     = []

  validation {
    condition = alltrue([
      for arn in var.additional_external_secret_arns :
      can(regex("^arn:[^:]+:secretsmanager:[^:]+:[0-9]{12}:secret:.+$", arn))
    ])
    error_message = "Every additional_external_secret_arns item must be a Secrets Manager secret ARN."
  }
}

variable "admin_role_arns" {
  description = "IAM roles that receive EKS cluster-admin access."
  type        = list(string)
  default     = []
}

variable "github_repositories" {
  description = "Repository identity for each least-privilege application publisher role."
  type        = map(string)
  default = {
    training  = "chiendz11/iris-data-pipeline"
    mlflow    = "chiendz11/iris-model-registry"
    inference = "chiendz11/iris-inference-service"
  }

  validation {
    condition = (
      length(var.github_repositories) == 3 &&
      length(setsubtract(
        toset(keys(var.github_repositories)),
        toset(["inference", "mlflow", "training"]),
      )) == 0 &&
      alltrue([
        for repository in values(var.github_repositories) :
        can(regex("^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$", repository))
      ])
    )
    error_message = "github_repositories must define valid training, mlflow and inference owner/name identities."
  }
}

variable "github_oidc_subject_prefixes" {
  description = "Exact GitHub OIDC sub_claim_prefix per repository, verified with the repository OIDC API. Non-secret identity configuration, not credentials."
  type        = map(string)
  default = {
    "chiendz11/iris-data-pipeline"     = "repo:chiendz11@169627609/iris-data-pipeline@1340834360"
    "chiendz11/iris-model-registry"    = "repo:chiendz11@169627609/iris-model-registry@1340834550"
    "chiendz11/iris-inference-service" = "repo:chiendz11@169627609/iris-inference-service@1340834663"
    "chiendz11/iris-gitops"            = "repo:chiendz11@169627609/iris-gitops@1342006443"
  }

  validation {
    condition = alltrue([
      for repository in concat(values(var.github_repositories), [var.gitops_repository]) : try(
        can(regex("^repo:[A-Za-z0-9_.-]+(@[0-9]+)?/[A-Za-z0-9_.-]+(@[0-9]+)?$", var.github_oidc_subject_prefixes[repository])) &&
        replace(var.github_oidc_subject_prefixes[repository], "/@[0-9]+/", "") == "repo:${repository}",
        false
      )
    ])
    error_message = "Every application and GitOps repository needs its matching exact OIDC subject prefix, without wildcards or context suffixes."
  }
}

variable "gitops_repository" {
  description = "GitOps repository whose trusted main workflows may read the GitOps automation credential through OIDC."
  type        = string
  default     = "chiendz11/iris-gitops"

  validation {
    condition     = can(regex("^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$", var.gitops_repository))
    error_message = "gitops_repository must use the owner/name format."
  }
}

variable "enable_public_domain" {
  description = "Consume the domain stack outputs and create ExternalDNS permissions."
  type        = bool
  default     = false
}

check "remote_state_inputs" {
  assert {
    condition     = var.state_bucket_name != null && var.state_kms_key_arn != null
    error_message = "state_bucket_name and state_kms_key_arn are required to read bootstrap state."
  }
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
