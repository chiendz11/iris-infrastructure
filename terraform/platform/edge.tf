data "terraform_remote_state" "domain" {
  count   = var.enable_public_domain ? 1 : 0
  backend = "s3"

  config = {
    bucket     = var.state_bucket_name
    key        = "infrastructure/domain.tfstate"
    region     = var.aws_region
    encrypt    = true
    kms_key_id = var.state_kms_key_arn
  }
}

locals {
  public_domain_name                     = try(data.terraform_remote_state.domain[0].outputs.domain_name, null)
  route53_zone_id                        = try(data.terraform_remote_state.domain[0].outputs.route53_zone_id, null)
  public_certificate_arn                 = try(data.terraform_remote_state.domain[0].outputs.public_certificate_arn, null)
  domain_ready                           = try(data.terraform_remote_state.domain[0].outputs.domain_ready, false)
  kserve_hostname                        = local.public_domain_name == null ? null : "${var.kserve_subdomain}.${local.public_domain_name}"
  aws_load_balancer_controller_role_name = "${local.name}-aws-load-balancer-controller"
}

check "public_domain_ready" {
  assert {
    condition     = !var.enable_public_domain || local.domain_ready
    error_message = "The domain stack must be delegated and its ACM certificate issued before enabling the platform public domain."
  }
}

check "aws_load_balancer_controller_role_name_length" {
  assert {
    condition     = length(local.aws_load_balancer_controller_role_name) <= 64
    error_message = "The AWS Load Balancer Controller IAM role name must not exceed the AWS 64-character limit."
  }
}

module "aws_load_balancer_controller_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts"
  version = "~> 6.0"

  name                                   = local.aws_load_balancer_controller_role_name
  use_name_prefix                        = false
  attach_load_balancer_controller_policy = true

  oidc_providers = {
    eks = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:aws-load-balancer-controller"]
    }
  }
}
