#!/usr/bin/env bash
# One-shot AWS CLI bootstrap for Terraform remote state (S3 + DynamoDB).
# Prefer `terraform apply` in this directory when the AWS provider loads cleanly.
# Usage: AWS_PROFILE=hait ./bootstrap.sh

set -euo pipefail

AWS_REGION="${AWS_REGION:-eu-west-2}"
STATE_BUCKET="${STATE_BUCKET:-vaathi-dev-tfstate}"
LOCK_TABLE="${LOCK_TABLE:-vaathi-dev-tf-locks}"

echo "Using profile=${AWS_PROFILE:-default} region=${AWS_REGION}"
aws sts get-caller-identity
aws configure set default.region "${AWS_REGION}" >/dev/null 2>&1 || true

if aws s3api head-bucket --bucket "${STATE_BUCKET}" 2>/dev/null; then
  echo "Bucket s3://${STATE_BUCKET} already exists"
else
  echo "Creating bucket s3://${STATE_BUCKET}"
  aws s3api create-bucket \
    --bucket "${STATE_BUCKET}" \
    --region "${AWS_REGION}" \
    --create-bucket-configuration LocationConstraint="${AWS_REGION}"
fi

aws s3api put-bucket-versioning \
  --bucket "${STATE_BUCKET}" \
  --versioning-configuration Status=Enabled

aws s3api put-bucket-encryption \
  --bucket "${STATE_BUCKET}" \
  --server-side-encryption-configuration '{
    "Rules": [{
      "ApplyServerSideEncryptionByDefault": {"SSEAlgorithm": "AES256"},
      "BucketKeyEnabled": true
    }]
  }'

aws s3api put-public-access-block \
  --bucket "${STATE_BUCKET}" \
  --public-access-block-configuration \
  BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true

aws s3api put-bucket-ownership-controls \
  --bucket "${STATE_BUCKET}" \
  --ownership-controls 'Rules=[{ObjectOwnership=BucketOwnerEnforced}]'

ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
POLICY="$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Sid": "DenyInsecureTransport",
    "Effect": "Deny",
    "Principal": "*",
    "Action": "s3:*",
    "Resource": [
      "arn:aws:s3:::${STATE_BUCKET}",
      "arn:aws:s3:::${STATE_BUCKET}/*"
    ],
    "Condition": {
      "Bool": {"aws:SecureTransport": "false"}
    }
  }]
}
EOF
)"
aws s3api put-bucket-policy --bucket "${STATE_BUCKET}" --policy "${POLICY}"

if aws dynamodb describe-table --table-name "${LOCK_TABLE}" --region "${AWS_REGION}" >/dev/null 2>&1; then
  echo "DynamoDB table ${LOCK_TABLE} already exists"
else
  echo "Creating DynamoDB table ${LOCK_TABLE}"
  aws dynamodb create-table \
    --table-name "${LOCK_TABLE}" \
    --attribute-definitions AttributeName=LockID,AttributeType=S \
    --key-schema AttributeName=LockID,KeyType=HASH \
    --billing-mode PAY_PER_REQUEST \
    --region "${AWS_REGION}" \
    --tags Key=Project,Value=vaathi.dev Key=Purpose,Value=tfstate-bootstrap
  aws dynamodb wait table-exists --table-name "${LOCK_TABLE}" --region "${AWS_REGION}"
fi

echo
echo "Bootstrap OK (account ${ACCOUNT_ID})"
echo "  bucket = ${STATE_BUCKET}"
echo "  table  = ${LOCK_TABLE}"
echo "  region = ${AWS_REGION}"
echo
echo "Write ../backend.hcl:"
cat <<EOF
bucket         = "${STATE_BUCKET}"
key            = "vaathi-dev/terraform.tfstate"
region         = "${AWS_REGION}"
encrypt        = true
dynamodb_table = "${LOCK_TABLE}"
EOF
