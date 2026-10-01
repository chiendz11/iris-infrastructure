resource "aws_route53_zone" "public" {
  count = var.enable_public_domain ? 1 : 0

  name    = var.domain_name
  comment = "Public DNS for ${var.project_name}-${var.environment}"

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_acm_certificate" "public" {
  count = var.enable_public_domain && var.domain_delegated ? 1 : 0

  domain_name               = var.domain_name
  subject_alternative_names = var.domain_name == null ? [] : ["*.${var.domain_name}"]
  validation_method         = "DNS"

  lifecycle {
    create_before_destroy = true
  }
}

locals {
  certificate_validation_options = var.enable_public_domain && var.domain_delegated ? {
    for option in aws_acm_certificate.public[0].domain_validation_options :
    option.resource_record_name => {
      name   = option.resource_record_name
      record = option.resource_record_value
      type   = option.resource_record_type
    }...
  } : {}
}

resource "aws_route53_record" "certificate_validation" {
  for_each = local.certificate_validation_options

  allow_overwrite = true
  zone_id         = aws_route53_zone.public[0].zone_id
  name            = each.value[0].name
  type            = each.value[0].type
  ttl             = 60
  records         = [each.value[0].record]
}

resource "aws_acm_certificate_validation" "public" {
  count = var.enable_public_domain && var.domain_delegated ? 1 : 0

  certificate_arn = aws_acm_certificate.public[0].arn
  validation_record_fqdns = [
    for record in aws_route53_record.certificate_validation : record.fqdn
  ]
}
