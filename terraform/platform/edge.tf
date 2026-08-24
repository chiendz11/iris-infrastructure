check "public_domain_inputs" {
  assert {
    condition = !var.enable_public_domain || (
      var.route53_zone_id != null && var.public_domain_name != null
    )
    error_message = "route53_zone_id and public_domain_name are required when enable_public_domain is true."
  }
}

locals {
  kserve_hostname = var.public_domain_name == null ? null : "${var.kserve_subdomain}.${var.public_domain_name}"
}

resource "aws_acm_certificate" "public" {
  count = var.enable_public_domain ? 1 : 0

  domain_name               = var.public_domain_name
  subject_alternative_names = var.public_domain_name == null ? [] : ["*.${var.public_domain_name}"]
  validation_method         = "DNS"

  lifecycle {
    create_before_destroy = true
  }
}

locals {
  public_certificate_validation_records = var.enable_public_domain ? {
    for option in aws_acm_certificate.public[0].domain_validation_options : option.domain_name => {
      name   = option.resource_record_name
      record = option.resource_record_value
      type   = option.resource_record_type
    }
  } : {}
}

resource "aws_route53_record" "public_certificate_validation" {
  for_each = local.public_certificate_validation_records

  allow_overwrite = true
  zone_id         = var.route53_zone_id
  name            = each.value.name
  type            = each.value.type
  ttl             = 60
  records         = [each.value.record]
}

resource "aws_acm_certificate_validation" "public" {
  count = var.enable_public_domain ? 1 : 0

  certificate_arn = aws_acm_certificate.public[0].arn
  validation_record_fqdns = [
    for record in aws_route53_record.public_certificate_validation : record.fqdn
  ]
}

module "aws_load_balancer_controller_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts"
  version = "~> 6.0"

  name                                   = "${local.name}-aws-load-balancer-controller"
  attach_load_balancer_controller_policy = true

  oidc_providers = {
    eks = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:aws-load-balancer-controller"]
    }
  }
}
