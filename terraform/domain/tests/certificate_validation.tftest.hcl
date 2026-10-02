mock_provider "aws" {}

run "certificate_validation_plan_has_static_keys" {
  command = plan

  variables {
    enable_public_domain = true
    domain_name          = "example.com"
    domain_delegated     = true
  }

  assert {
    condition     = length(aws_route53_record.certificate_validation) == 1
    error_message = "The apex and wildcard certificate must share one statically-addressed validation record."
  }
}
