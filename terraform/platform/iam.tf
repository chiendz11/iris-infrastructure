data "aws_iam_policy_document" "irsa_trust" {
  for_each = local.service_accounts

  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    effect  = "Allow"

    principals {
      type        = "Federated"
      identifiers = [module.eks.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(module.eks.cluster_oidc_issuer_url, "https://", "")}:sub"
      values   = ["system:serviceaccount:${each.value.namespace}:${each.value.name}"]
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(module.eks.cluster_oidc_issuer_url, "https://", "")}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "service_account" {
  for_each           = local.service_accounts
  name               = "${local.name}-${replace(each.key, "_", "-")}"
  assume_role_policy = data.aws_iam_policy_document.irsa_trust[each.key].json
}

data "aws_iam_policy_document" "mlflow" {
  statement {
    actions   = ["s3:ListBucket", "s3:GetBucketLocation"]
    resources = [aws_s3_bucket.platform["mlflow"].arn]
  }

  statement {
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = ["${aws_s3_bucket.platform["mlflow"].arn}/*"]
  }
}

data "aws_iam_policy_document" "training" {
  statement {
    actions = ["s3:ListBucket", "s3:GetBucketLocation"]
    resources = [
      aws_s3_bucket.platform["dvc"].arn,
      aws_s3_bucket.platform["argo"].arn
    ]
  }

  statement {
    actions = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = [
      "${aws_s3_bucket.platform["dvc"].arn}/*",
      "${aws_s3_bucket.platform["argo"].arn}/*"
    ]
  }
}

data "aws_iam_policy_document" "argo_events" {
  statement {
    actions = [
      "sqs:ReceiveMessage",
      "sqs:DeleteMessage",
      "sqs:GetQueueAttributes",
      "sqs:GetQueueUrl"
    ]
    resources = [aws_sqs_queue.dataset_events.arn]
  }
}

data "aws_iam_policy_document" "external_secrets" {
  statement {
    actions = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
    resources = concat(
      [
        aws_db_instance.mlflow.master_user_secret[0].secret_arn,
        aws_secretsmanager_secret.model_release_publisher_github_app.arn,
      ],
      var.additional_external_secret_arns
    )
  }
}

data "aws_iam_policy_document" "external_dns" {
  count = var.enable_public_domain ? 1 : 0

  statement {
    actions   = ["route53:ChangeResourceRecordSets"]
    resources = local.route53_zone_id == null ? [] : ["arn:aws:route53:::hostedzone/${local.route53_zone_id}"]
  }

  statement {
    actions = [
      "route53:ListHostedZones",
      "route53:ListResourceRecordSets",
      "route53:ListTagsForResource"
    ]
    resources = ["*"]
  }
}

resource "aws_iam_policy" "service_account" {
  for_each = merge({
    mlflow           = data.aws_iam_policy_document.mlflow.json
    training         = data.aws_iam_policy_document.training.json
    argo_events      = data.aws_iam_policy_document.argo_events.json
    external_secrets = data.aws_iam_policy_document.external_secrets.json
    }, var.enable_public_domain ? {
    external_dns = data.aws_iam_policy_document.external_dns[0].json
  } : {})

  name   = "${local.name}-${replace(each.key, "_", "-")}"
  policy = each.value
}

resource "aws_iam_role_policy_attachment" "service_account" {
  for_each   = aws_iam_policy.service_account
  role       = aws_iam_role.service_account[each.key].name
  policy_arn = each.value.arn
}

data "aws_iam_policy_document" "github_application_trust" {
  for_each = var.github_repositories

  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:oidc-provider/token.actions.githubusercontent.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${each.value}:environment:prod"]
    }
  }
}

resource "aws_iam_role" "github_application_publisher" {
  for_each           = var.github_repositories
  name               = "${local.name}-github-${replace(each.key, "_", "-")}-publisher"
  assume_role_policy = data.aws_iam_policy_document.github_application_trust[each.key].json
}

data "aws_iam_policy_document" "github_application_publisher" {
  for_each = var.github_repositories

  statement {
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:CompleteLayerUpload",
      "ecr:GetDownloadUrlForLayer",
      "ecr:InitiateLayerUpload",
      "ecr:PutImage",
      "ecr:UploadLayerPart",
      "ecr:BatchGetImage",
      "ecr:DescribeImages"
    ]
    resources = [aws_ecr_repository.services[each.key].arn]
  }

  dynamic "statement" {
    for_each = each.key == "training" ? [true] : []
    content {
      actions   = ["s3:ListBucket", "s3:GetBucketLocation"]
      resources = [aws_s3_bucket.platform["dvc"].arn]
    }
  }

  dynamic "statement" {
    for_each = each.key == "training" ? [true] : []
    content {
      actions   = ["s3:GetObject", "s3:PutObject"]
      resources = ["${aws_s3_bucket.platform["dvc"].arn}/*"]
    }
  }
}

resource "aws_iam_role_policy" "github_application_publisher" {
  for_each = var.github_repositories
  name     = "build-and-publish"
  role     = aws_iam_role.github_application_publisher[each.key].id
  policy   = data.aws_iam_policy_document.github_application_publisher[each.key].json
}

data "aws_iam_policy_document" "github_gitops_automation_trust" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [data.terraform_remote_state.bootstrap.outputs.github_oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${var.gitops_repository}:ref:refs/heads/main"]
    }
  }
}

resource "aws_iam_role" "github_gitops_automation" {
  name               = "${local.name}-github-gitops-automation"
  assume_role_policy = data.aws_iam_policy_document.github_gitops_automation_trust.json
}

data "aws_iam_policy_document" "github_gitops_automation" {
  statement {
    actions = [
      "secretsmanager:DescribeSecret",
      "secretsmanager:GetSecretValue",
    ]
    resources = [aws_secretsmanager_secret.gitops_automation_github_app.arn]
  }

  # Renderer workflows verify immutable Cosign signatures before opening a
  # release PR. They can inspect images but cannot upload, retag or delete any.
  statement {
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:BatchGetImage",
      "ecr:DescribeImages",
      "ecr:GetDownloadUrlForLayer",
    ]
    resources = [for repository in aws_ecr_repository.services : repository.arn]
  }
}

resource "aws_iam_role_policy" "github_gitops_automation" {
  name   = "read-gitops-automation-secret"
  role   = aws_iam_role.github_gitops_automation.id
  policy = data.aws_iam_policy_document.github_gitops_automation.json
}

data "aws_iam_policy_document" "github_release_automation_publish_trust" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [data.terraform_remote_state.bootstrap.outputs.github_oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${var.gitops_repository}:ref:refs/heads/main"]
    }
  }
}

resource "aws_iam_role" "github_release_automation_publish" {
  name               = "${local.name}-github-release-automation-publish"
  assume_role_policy = data.aws_iam_policy_document.github_release_automation_publish_trust.json
}

data "aws_iam_policy_document" "github_release_automation_publish" {
  statement {
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:CompleteLayerUpload",
      "ecr:GetDownloadUrlForLayer",
      "ecr:InitiateLayerUpload",
      "ecr:PutImage",
      "ecr:UploadLayerPart",
      "ecr:BatchGetImage",
      "ecr:DescribeImages",
    ]
    resources = [aws_ecr_repository.services["dispatcher"].arn]
  }
}

resource "aws_iam_role_policy" "github_release_automation_publish" {
  name   = "publish-release-automation-image"
  role   = aws_iam_role.github_release_automation_publish.id
  policy = data.aws_iam_policy_document.github_release_automation_publish.json
}
