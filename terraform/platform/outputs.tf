output "cluster_name" {
  value = module.eks.cluster_name
}

output "cluster_endpoint" {
  value = module.eks.cluster_endpoint
}

output "vpc_id" {
  value = module.vpc.vpc_id
}

output "availability_zones" {
  value = local.azs
}

output "vpc_endpoint_ids" {
  value = {
    for key, endpoint in module.vpc_endpoints.endpoints : key => endpoint.id
  }
}

output "dvc_bucket" {
  value = aws_s3_bucket.platform["dvc"].bucket
}

output "mlflow_artifact_bucket" {
  value = aws_s3_bucket.platform["mlflow"].bucket
}

output "argo_artifact_bucket" {
  value = aws_s3_bucket.platform["argo"].bucket
}

output "dataset_event_queue_url" {
  value = aws_sqs_queue.dataset_events.url
}

output "dataset_event_queue_name" {
  value = aws_sqs_queue.dataset_events.name
}

output "dataset_event_queue_arn" {
  value = aws_sqs_queue.dataset_events.arn
}

output "rds_endpoint" {
  value = aws_db_instance.mlflow.address
}

output "rds_multi_az" {
  value = aws_db_instance.mlflow.multi_az
}

output "rds_master_secret_arn" {
  value = aws_db_instance.mlflow.master_user_secret[0].secret_arn
}

output "ecr_repository_urls" {
  value = {
    for key, repository in aws_ecr_repository.services : key => repository.repository_url
  }
}

output "ecr_repository_names" {
  value = {
    for key, repository in aws_ecr_repository.services : key => repository.name
  }
}

output "service_account_role_arns" {
  value = {
    for key, role in aws_iam_role.service_account : key => role.arn
  }
}

output "github_actions_role_arn" {
  value = aws_iam_role.github_actions.arn
}

output "aws_load_balancer_controller_role_arn" {
  value = module.aws_load_balancer_controller_irsa.arn
}

output "external_dns_role_arn" {
  value = try(aws_iam_role.service_account["external_dns"].arn, null)
}

output "public_certificate_arn" {
  value = try(aws_acm_certificate_validation.public[0].certificate_arn, null)
}

output "kserve_hostname" {
  value = local.kserve_hostname
}

output "public_domain_name" {
  value = var.public_domain_name
}

output "route53_zone_id" {
  value = var.route53_zone_id
}

output "kserve_public_url" {
  value = var.enable_public_domain ? "https://${local.kserve_hostname}" : null
}
