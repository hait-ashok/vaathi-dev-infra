variable "aws_region" {
  description = "Region for state bucket and lock table."
  type        = string
  default     = "eu-west-2"
}

variable "state_bucket_name" {
  description = "Globally unique S3 bucket for Terraform state."
  type        = string
  default     = "vaathi-dev-tfstate"
}

variable "lock_table_name" {
  description = "DynamoDB table for Terraform state locking."
  type        = string
  default     = "vaathi-dev-tf-locks"
}
