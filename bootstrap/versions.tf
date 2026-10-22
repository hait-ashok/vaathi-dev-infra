terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.80"
    }
  }

  # Bootstrap intentionally uses local state (one-shot).
  # Do not commit *.tfstate* — see ../.gitignore.
}
