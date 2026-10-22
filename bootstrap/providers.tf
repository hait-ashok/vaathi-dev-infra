provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project   = "vaathi.dev"
      ManagedBy = "terraform"
      Purpose   = "tfstate-bootstrap"
      Repo      = "vaathi-dev-infra"
    }
  }
}
