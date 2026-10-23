output "route53_name_servers" {
  description = "Paste these as the nameservers for vaathi.dev at GoDaddy (replace GoDaddy defaults)."
  value       = aws_route53_zone.site.name_servers
}

output "route53_zone_id" {
  value = aws_route53_zone.site.zone_id
}

output "site_bucket_name" {
  description = "GitHub Actions var: AWS_S3_BUCKET"
  value       = aws_s3_bucket.site.id
}

output "cloudfront_distribution_id" {
  description = "GitHub Actions var: AWS_CLOUDFRONT_DISTRIBUTION_ID"
  value       = aws_cloudfront_distribution.site.id
}

output "cloudfront_domain_name" {
  value = aws_cloudfront_distribution.site.domain_name
}

output "github_deploy_role_arn" {
  description = "GitHub Actions var: AWS_DEPLOY_ROLE_ARN"
  value       = aws_iam_role.github_deploy.arn
}

output "acm_certificate_arn" {
  value = aws_acm_certificate.site.arn
}

output "canonical_site_url" {
  value = "https://${var.domain_name}"
}

output "github_oidc_trust_sub" {
  description = "Subject claim required on the deploy role trust policy."
  value       = local.github_sub
}

output "github_actions_vars" {
  description = "Copy into the app repo Settings → Secrets and variables → Actions → Variables"
  value = {
    AWS_REGION                     = var.aws_region
    AWS_DEPLOY_ROLE_ARN            = aws_iam_role.github_deploy.arn
    AWS_S3_BUCKET                  = aws_s3_bucket.site.id
    AWS_CLOUDFRONT_DISTRIBUTION_ID = aws_cloudfront_distribution.site.id
  }
}

output "github_terraform_role_arn" {
  description = "GitHub Actions var (infra repo): AWS_TERRAFORM_ROLE_ARN"
  value       = aws_iam_role.github_terraform.arn
}

output "github_terraform_oidc_subjects" {
  description = "Subject claims required on the terraform role trust policy."
  value = {
    main         = local.github_terraform_sub_main
    pull_request = local.github_terraform_sub_pr
  }
}

output "github_actions_infra_vars" {
  description = "Copy into the infra repo Settings → Secrets and variables → Actions → Variables"
  value = {
    AWS_REGION             = var.aws_region
    AWS_TERRAFORM_ROLE_ARN = aws_iam_role.github_terraform.arn
  }
}
