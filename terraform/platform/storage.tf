resource "random_id" "suffix" {
  byte_length = 4
}

locals {
  buckets = {
    mlflow = "${local.name}-mlflow-${random_id.suffix.hex}"
    dvc    = "${local.name}-dvc-${random_id.suffix.hex}"
    argo   = "${local.name}-argo-${random_id.suffix.hex}"
  }
}

resource "aws_s3_bucket" "platform" {
  for_each = local.buckets
  bucket   = each.value
}

resource "aws_s3_bucket_versioning" "platform" {
  for_each = aws_s3_bucket.platform
  bucket   = each.value.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "platform" {
  for_each = aws_s3_bucket.platform
  bucket   = each.value.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "platform" {
  for_each                = aws_s3_bucket.platform
  bucket                  = each.value.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "platform" {
  for_each = aws_s3_bucket.platform
  bucket   = each.value.id

  rule {
    id     = "abort-incomplete-uploads"
    status = "Enabled"
    filter {}

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }

    noncurrent_version_expiration {
      noncurrent_days = 90
    }
  }
}

resource "aws_sqs_queue" "dataset_dlq" {
  name                      = "${local.name}-dataset-events-dlq"
  message_retention_seconds = 1209600
  sqs_managed_sse_enabled   = true
}

resource "aws_sqs_queue" "dataset_events" {
  name                       = "${local.name}-dataset-events"
  visibility_timeout_seconds = 300
  message_retention_seconds  = 345600
  sqs_managed_sse_enabled    = true
  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.dataset_dlq.arn
    maxReceiveCount     = 5
  })
}

resource "aws_sqs_queue_policy" "dataset_events" {
  queue_url = aws_sqs_queue.dataset_events.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "AllowDvcBucketNotifications"
      Effect    = "Allow"
      Principal = { Service = "s3.amazonaws.com" }
      Action    = "sqs:SendMessage"
      Resource  = aws_sqs_queue.dataset_events.arn
      Condition = {
        ArnEquals = {
          "aws:SourceArn" = aws_s3_bucket.platform["dvc"].arn
        }
        StringEquals = {
          "aws:SourceAccount" = data.aws_caller_identity.current.account_id
        }
      }
    }]
  })
}

resource "aws_s3_bucket_notification" "dataset_events" {
  bucket = aws_s3_bucket.platform["dvc"].id

  queue {
    queue_arn     = aws_sqs_queue.dataset_events.arn
    events        = ["s3:ObjectCreated:*"]
    filter_prefix = "datasets/"
    filter_suffix = ".csv"
  }

  depends_on = [aws_sqs_queue_policy.dataset_events]
}

resource "aws_ecr_repository" "services" {
  for_each             = toset(["training", "mlflow", "inference", "dispatcher"])
  name                 = "${local.name}/${each.key}"
  image_tag_mutability = "IMMUTABLE_WITH_EXCLUSION"

  # Release tags remain immutable. Cosign's OCI 1.1 fallback writes signatures
  # as sha256-* tags and must be able to replace the same signature on retries.
  image_tag_mutability_exclusion_filter {
    filter      = "sha256-*"
    filter_type = "WILDCARD"
  }

  image_scanning_configuration {
    scan_on_push = true
  }
}

resource "aws_ecr_lifecycle_policy" "services" {
  for_each   = aws_ecr_repository.services
  repository = each.value.name
  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Expire only untagged build debris after 14 days"
      selection = {
        tagStatus   = "untagged"
        countType   = "sinceImagePushed"
        countUnit   = "days"
        countNumber = 14
      }
      action = { type = "expire" }
    }]
  })
}
