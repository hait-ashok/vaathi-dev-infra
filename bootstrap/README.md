# Terraform state bootstrap

One-shot stack that creates the **S3 state bucket** + **DynamoDB lock table** for the main `vaathi-dev-infra` root.

## Important

- Uses **local state** in this directory (`bootstrap/terraform.tfstate`) — **never commit** it (repo root `.gitignore` covers `*.tfstate*`).
- Back up `bootstrap/terraform.tfstate` somewhere private after apply (or later migrate bootstrap state into the same bucket under a separate key).
- Run with a working AWS profile, e.g. `export AWS_PROFILE=hait`.

## Apply (preferred: Terraform)

```bash
cd ~/vaathi-dev-infra/bootstrap
export AWS_PROFILE=hait   # or your H&A account profile
terraform init
terraform apply
terraform output -raw backend_hcl_snippet
```

## Apply (fallback: AWS CLI)

If the AWS provider plugin fails to start (`timeout while waiting for plugin to start`), use the equivalent script:

```bash
cd ~/vaathi-dev-infra
export AWS_PROFILE=hait
./bootstrap/bootstrap.sh
```

Then at the **repo root**:

```bash
cd ~/vaathi-dev-infra
# write gitignored backend.hcl (from script output or example)
cat > backend.hcl <<'EOF'
bucket         = "vaathi-dev-tfstate"
key            = "vaathi-dev/terraform.tfstate"
region         = "eu-west-2"
encrypt        = true
dynamodb_table = "vaathi-dev-tf-locks"
EOF

terraform init -backend-config=backend.hcl
# answer yes to migrate local state if prompted
```

Do **not** delete the state bucket/table while the main site state still lives there.

Optional later: `terraform import` the CLI-created bucket/table into this bootstrap root so destroy is TF-managed.
