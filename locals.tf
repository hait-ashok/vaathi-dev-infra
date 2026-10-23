locals {
  www_domain = "www.${var.domain_name}"

  common_tags = {
    Project   = var.project
    ManagedBy = "terraform"
    Repo      = "vaathi-dev-infra"
  }

  # GitHub OIDC subject for Actions on the deploy branch.
  # Repos created after 2026-07-15 (or opted in) use immutable IDs: OWNER@OWNER_ID/REPO@REPO_ID.
  github_owner_claim = var.github_org_id != "" ? "${var.github_org}@${var.github_org_id}" : var.github_org
  github_repo_claim  = var.github_repo_id != "" ? "${var.github_app_repo}@${var.github_repo_id}" : var.github_app_repo
  github_sub         = "repo:${local.github_owner_claim}/${local.github_repo_claim}:ref:refs/heads/${var.github_deploy_branch}"
}
