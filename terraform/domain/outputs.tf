output "domain_name" {
  value = try(aws_route53_zone.public[0].name, null)
}

output "route53_zone_id" {
  value = try(aws_route53_zone.public[0].zone_id, null)
}

output "route53_name_servers" {
  description = "Delegate these name servers at the registrar before approving the DNS gate."
  value       = try(aws_route53_zone.public[0].name_servers, [])
}

output "public_certificate_arn" {
  value = try(aws_acm_certificate_validation.public[0].certificate_arn, null)
}

output "domain_ready" {
  value = (
    var.enable_public_domain &&
    var.domain_delegated &&
    try(aws_acm_certificate_validation.public[0].certificate_arn, null) != null
  )
}
