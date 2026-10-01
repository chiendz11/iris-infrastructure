data "terraform_remote_state" "bootstrap" {
  backend = "s3"

  config = {
    bucket     = var.state_bucket_name
    key        = "infrastructure/bootstrap.tfstate"
    region     = var.aws_region
    encrypt    = true
    kms_key_id = var.state_kms_key_arn
  }
}

locals {
  terraform_apply_role_arn = data.terraform_remote_state.bootstrap.outputs.terraform_apply_role_arn
}
