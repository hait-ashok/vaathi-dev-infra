terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.80"
    }
  }

  # Optional remote state — see backend.hcl.example and README.
  # Uncomment after creating the state bucket, then:
  #   terraform init -backend-config=backend.hcl
  #
  # backend "s3" {}
}
