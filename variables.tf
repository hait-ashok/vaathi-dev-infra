variable "aws_region" {
  description = "Primary region for S3 origin and most resources (not ACM for CloudFront)."
  type        = string
  default     = "eu-west-2"
}

variable "project" {
  description = "Project tag / name prefix."
  type        = string
  default     = "vaathi.dev"
}

variable "domain_name" {
  description = "Apex domain (canonical site URL)."
  type        = string
  default     = "vaathi.dev"
}

variable "bucket_name" {
  description = "Private S3 origin bucket. Must be globally unique."
  type        = string
  default     = "vaathi-dev-site-prod"
}

variable "github_org" {
  description = "GitHub org or user that owns the app repo (OIDC trust)."
  type        = string
  default     = "hait-ashok"
}

variable "github_app_repo" {
  description = "App repository name (static site) trusted for deploy via OIDC."
  type        = string
  default     = "vaathi.dev"
}

variable "github_deploy_branch" {
  description = "Git branch allowed to assume the deploy role."
  type        = string
  default     = "main"
}

variable "create_github_oidc_provider" {
  description = "Set false and pass github_oidc_provider_arn if the account already has the GitHub OIDC provider."
  type        = bool
  default     = true
}

variable "github_oidc_provider_arn" {
  description = "Existing GitHub OIDC provider ARN when create_github_oidc_provider is false."
  type        = string
  default     = ""
}
