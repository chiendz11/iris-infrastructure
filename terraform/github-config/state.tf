data "terraform_remote_state" "foundation" {
  backend = "s3"

  config = {
    bucket     = var.state_bucket_name
    key        = "infrastructure/bootstrap.tfstate"
    region     = var.aws_region
    encrypt    = true
    kms_key_id = var.state_kms_key_arn
  }
}

data "terraform_remote_state" "platform" {
  count   = var.manage_application_config ? 1 : 0
  backend = "s3"

  config = {
    bucket     = var.state_bucket_name
    key        = "infrastructure/platform.tfstate"
    region     = var.aws_region
    encrypt    = true
    kms_key_id = var.state_kms_key_arn
  }
}
