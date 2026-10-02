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
  # ACM exposes domain_validation_options only after the certificate request,
  # so those computed values cannot identify for_each instances in the initial
  # plan. The certificate contains only the apex and its wildcard; ACM documents
  # that this pair shares one validation CNAME. Use the configured apex as the
  # stable instance key and keep all apply-time values in resource arguments.
  certificate_validation_domains = var.enable_public_domain && var.domain_delegated ? toset([var.domain_name]) : toset([])
}

resource "aws_route53_record" "certificate_validation" {
  for_each = local.certificate_validation_domains

  allow_overwrite = true
  zone_id         = aws_route53_zone.public[0].zone_id
  name = one(distinct([
    for option in aws_acm_certificate.public[0].domain_validation_options : option.resource_record_name
  ]))
  type = one(distinct([
    for option in aws_acm_certificate.public[0].domain_validation_options : option.resource_record_type
  ]))
  ttl = 60
  records = [one(distinct([
    for option in aws_acm_certificate.public[0].domain_validation_options : option.resource_record_value
  ]))]
}

resource "aws_acm_certificate_validation" "public" {
  count = var.enable_public_domain && var.domain_delegated ? 1 : 0

  certificate_arn = aws_acm_certificate.public[0].arn
  validation_record_fqdns = [
    for record in aws_route53_record.certificate_validation : record.fqdn
  ]
}
