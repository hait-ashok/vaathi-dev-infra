terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.80"
    }
  }

  # Partial S3 backend — pass the rest via backend.hcl (gitignored):
  #   terraform init -backend-config=backend.hcl
  # Create bucket + lock table first: see bootstrap/
  backend "s3" {}
}
