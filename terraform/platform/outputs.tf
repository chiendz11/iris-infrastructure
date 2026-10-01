output "cluster_name" {
  value = module.eks.cluster_name
}

output "ebs_csi_addon_version" {
  description = "Resolved EBS CSI EKS build; pin this reviewed value for reproducible upgrades."
  value       = aws_eks_addon.ebs_csi.addon_version
}

output "ebs_csi_driver_role_arn" {
  description = "Dedicated IRSA role for kube-system/ebs-csi-controller-sa, not an application role."
  value       = aws_iam_role.ebs_csi.arn
}

output "aws_region" {
  description = "AWS region containing the production platform."
  value       = var.aws_region
}

output "cluster_endpoint" {
  value = module.eks.cluster_endpoint
}

output "argocd_chart_version" {
  description = "Argo CD chart version owned by the Terraform Helm release."
  value       = helm_release.argocd.version
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

output "model_release_publisher_github_app_secret_arn" {
  description = "Secret container for the Actions-only model-release publisher App used in cluster; Terraform never manages its value."
  value       = aws_secretsmanager_secret.model_release_publisher_github_app.arn
}

output "gitops_automation_github_app_secret_arn" {
  description = "Secret container for the GitOps renderer App; Terraform never manages its value."
  value       = aws_secretsmanager_secret.gitops_automation_github_app.arn
}

output "github_gitops_automation_role_arn" {
  description = "OIDC role used by trusted GitOps renderer workflows to read their PR automation credential."
  value       = aws_iam_role.github_gitops_automation.arn
}

output "github_release_automation_publish_role_arn" {
  description = "OIDC role used by iris-gitops/main to publish only the release-automation image to the physical dispatcher ECR repository."
  value       = aws_iam_role.github_release_automation_publish.arn
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

output "github_application_publisher_role_arns" {
  description = "Repository-bound OIDC publisher role for each application component."
  value = {
    for component, role in aws_iam_role.github_application_publisher : component => role.arn
  }
}

output "aws_load_balancer_controller_role_arn" {
  value = module.aws_load_balancer_controller_irsa.arn
}

output "external_dns_role_arn" {
  value = try(aws_iam_role.service_account["external_dns"].arn, null)
}

output "public_certificate_arn" {
  value = local.public_certificate_arn
}

output "kserve_hostname" {
  value = local.kserve_hostname
}

output "public_domain_name" {
  value = local.public_domain_name
}

output "route53_zone_id" {
  value = local.route53_zone_id
}

output "kserve_public_url" {
  value = var.enable_public_domain ? "https://${local.kserve_hostname}" : null
}
