locals {
  www_domain = "www.${var.domain_name}"

  common_tags = {
    Project   = var.project
    ManagedBy = "terraform"
    Repo      = "vaathi-dev-infra"
  }

  # GitHub OIDC subject for Actions on the deploy branch.
  github_sub = "repo:${var.github_org}/${var.github_app_repo}:ref:refs/heads/${var.github_deploy_branch}"
}
