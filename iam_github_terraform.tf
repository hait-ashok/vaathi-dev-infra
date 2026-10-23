# GitHub Actions OIDC role for Terraform plan/apply on this infra repo.
# Separate from vaathi-dev-github-deploy (app S3 sync + CloudFront invalidate only).

locals {
  github_infra_owner_claim = var.github_org_id != "" ? "${var.github_org}@${var.github_org_id}" : var.github_org
  github_infra_repo_claim  = var.github_infra_repo_id != "" ? "${var.github_infra_repo}@${var.github_infra_repo_id}" : var.github_infra_repo

  # Immutable subjects when org/repo IDs are set (required for this infra repo).
  github_terraform_sub_main = "repo:${local.github_infra_owner_claim}/${local.github_infra_repo_claim}:ref:refs/heads/${var.github_infra_branch}"
  github_terraform_sub_pr   = "repo:${local.github_infra_owner_claim}/${local.github_infra_repo_claim}:pull_request"

  tfstate_bucket_arn = "arn:aws:s3:::${var.tfstate_bucket_name}"
  tf_locks_table_arn = "arn:aws:dynamodb:${var.aws_region}:${data.aws_caller_identity.current.account_id}:table/${var.tf_locks_table_name}"
}

data "aws_iam_policy_document" "github_terraform_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [local.github_oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values = [
        local.github_terraform_sub_main,
        local.github_terraform_sub_pr,
      ]
    }
  }
}

resource "aws_iam_role" "github_terraform" {
  name               = "vaathi-dev-github-terraform"
  assume_role_policy = data.aws_iam_policy_document.github_terraform_assume.json
  description        = "GitHub Actions OIDC Terraform for ${var.github_org}/${var.github_infra_repo}"
}

data "aws_iam_policy_document" "github_terraform" {
  # --- Terraform remote state ---
  statement {
    sid    = "TfStateBucketList"
    effect = "Allow"
    actions = [
      "s3:ListBucket",
      "s3:GetBucketVersioning",
      "s3:GetBucketLocation",
    ]
    resources = [local.tfstate_bucket_arn]
  }

  statement {
    sid    = "TfStateObjects"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
    ]
    resources = ["${local.tfstate_bucket_arn}/*"]
  }

  statement {
    sid    = "TfStateLock"
    effect = "Allow"
    actions = [
      "dynamodb:DescribeTable",
      "dynamodb:GetItem",
      "dynamodb:PutItem",
      "dynamodb:DeleteItem",
    ]
    resources = [local.tf_locks_table_arn]
  }

  # --- Site origin bucket ---
  # Full s3:* on this bucket: Terraform refresh reads attributes whose IAM
  # names are not under GetBucket* (e.g. s3:GetAccelerateConfiguration).
  statement {
    sid    = "SiteBucket"
    effect = "Allow"
    actions = [
      "s3:*",
    ]
    resources = [
      aws_s3_bucket.site.arn,
      "${aws_s3_bucket.site.arn}/*",
    ]
  }

  # --- CloudFront (distribution + OAC + function + response headers) ---
  # List/create APIs often require Resource "*"; tighten later if needed.
  statement {
    sid    = "CloudFrontManage"
    effect = "Allow"
    actions = [
      "cloudfront:CreateDistribution",
      "cloudfront:UpdateDistribution",
      "cloudfront:DeleteDistribution",
      "cloudfront:GetDistribution",
      "cloudfront:GetDistributionConfig",
      "cloudfront:ListDistributions",
      "cloudfront:TagResource",
      "cloudfront:UntagResource",
      "cloudfront:ListTagsForResource",
      "cloudfront:CreateInvalidation",
      "cloudfront:GetInvalidation",
      "cloudfront:ListInvalidations",
      "cloudfront:CreateOriginAccessControl",
      "cloudfront:GetOriginAccessControl",
      "cloudfront:GetOriginAccessControlConfig",
      "cloudfront:UpdateOriginAccessControl",
      "cloudfront:DeleteOriginAccessControl",
      "cloudfront:ListOriginAccessControls",
      "cloudfront:CreateFunction",
      "cloudfront:DescribeFunction",
      "cloudfront:GetFunction",
      "cloudfront:UpdateFunction",
      "cloudfront:DeleteFunction",
      "cloudfront:PublishFunction",
      "cloudfront:ListFunctions",
      "cloudfront:CreateResponseHeadersPolicy",
      "cloudfront:GetResponseHeadersPolicy",
      "cloudfront:GetResponseHeadersPolicyConfig",
      "cloudfront:UpdateResponseHeadersPolicy",
      "cloudfront:DeleteResponseHeadersPolicy",
      "cloudfront:ListResponseHeadersPolicies",
    ]
    resources = ["*"]
  }

  # --- Route 53 (hosted zone + records for this domain) ---
  statement {
    sid    = "Route53Zone"
    effect = "Allow"
    actions = [
      "route53:GetHostedZone",
      "route53:DeleteHostedZone",
      "route53:ListResourceRecordSets",
      "route53:ChangeResourceRecordSets",
      "route53:GetChange",
      "route53:ListTagsForResource",
      "route53:ChangeTagsForResource",
    ]
    resources = [
      aws_route53_zone.site.arn,
      "arn:aws:route53:::change/*",
    ]
  }

  statement {
    sid       = "Route53List"
    effect    = "Allow"
    actions   = ["route53:ListHostedZones", "route53:ListHostedZonesByName"]
    resources = ["*"]
  }

  # --- ACM (CloudFront cert in us-east-1) ---
  statement {
    sid    = "AcmManage"
    effect = "Allow"
    actions = [
      "acm:RequestCertificate",
      "acm:DescribeCertificate",
      "acm:DeleteCertificate",
      "acm:ListCertificates",
      "acm:ListTagsForCertificate",
      "acm:AddTagsToCertificate",
      "acm:RemoveTagsFromCertificate",
    ]
    resources = ["*"]
  }

  # --- IAM: only the deploy + terraform roles for this stack ---
  statement {
    sid    = "IamManageStackRoles"
    effect = "Allow"
    actions = [
      "iam:GetRole",
      "iam:GetRolePolicy",
      "iam:ListRolePolicies",
      "iam:ListAttachedRolePolicies",
      "iam:UpdateAssumeRolePolicy",
      "iam:PutRolePolicy",
      "iam:DeleteRolePolicy",
      "iam:TagRole",
      "iam:UntagRole",
      "iam:ListRoleTags",
      "iam:PassRole",
    ]
    resources = [
      aws_iam_role.github_deploy.arn,
      aws_iam_role.github_terraform.arn,
    ]
  }

  statement {
    sid       = "IamReadOidcProvider"
    effect    = "Allow"
    actions   = ["iam:GetOpenIDConnectProvider"]
    resources = [local.github_oidc_provider_arn]
  }

  statement {
    sid       = "StsIdentity"
    effect    = "Allow"
    actions   = ["sts:GetCallerIdentity"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "github_terraform" {
  name   = "vaathi-dev-github-terraform"
  role   = aws_iam_role.github_terraform.id
  policy = data.aws_iam_policy_document.github_terraform.json
}
