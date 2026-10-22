output "state_bucket_name" {
  value = aws_s3_bucket.tfstate.id
}

output "state_bucket_arn" {
  value = aws_s3_bucket.tfstate.arn
}

output "lock_table_name" {
  value = aws_dynamodb_table.tf_locks.name
}

output "lock_table_arn" {
  value = aws_dynamodb_table.tf_locks.arn
}

output "backend_hcl_snippet" {
  description = "Copy into ../backend.hcl (gitignored) for the main stack."
  value       = <<-EOT
    bucket         = "${aws_s3_bucket.tfstate.id}"
    key            = "vaathi-dev/terraform.tfstate"
    region         = "${var.aws_region}"
    encrypt        = true
    dynamodb_table = "${aws_dynamodb_table.tf_locks.name}"
  EOT
}
