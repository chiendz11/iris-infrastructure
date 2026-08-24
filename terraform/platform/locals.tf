locals {
  name = "${var.project_name}-${var.environment}"
  azs  = slice(data.aws_availability_zones.available.names, 0, var.az_count)

  access_entries = {
    for index, arn in var.admin_role_arns : "admin-${index}" => {
      principal_arn = arn
      policy_associations = {
        admin = {
          policy_arn   = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
          access_scope = { type = "cluster" }
        }
      }
    }
  }

  service_accounts = merge({
    mlflow           = { namespace = "mlops", name = "mlflow" }
    training         = { namespace = "argo", name = "iris-training" }
    argo_events      = { namespace = "argo-events", name = "sqs-eventsource-sa" }
    external_secrets = { namespace = "external-secrets", name = "external-secrets" }
    }, var.enable_public_domain ? {
    external_dns = { namespace = "external-dns", name = "external-dns" }
  } : {})
}
