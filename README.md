# vaathi-dev-infra

Terraform for **vaathi.dev** static hosting:

- Route 53 public hosted zone → **nameservers for GoDaddy**
- Private S3 + CloudFront OAC
- ACM (us-east-1) for `vaathi.dev` + `www.vaathi.dev`
- **www → apex** via CloudFront Function (301)
- Security response headers; default root `index.html`; 404 → `/404.html`
- IAM role + GitHub OIDC for the **app** repo deploy

App content lives in a separate repo (`vaathi.dev`). This repo never builds Astro.

## Prerequisites

- Terraform ≥ 1.5
- AWS credentials for the H&A account (`AWS_PROFILE=hait aws sts get-caller-identity` must work)
- GitHub app repo (default trust: `hait-ashok/vaathi.dev` on `main`)

## Terraform state (S3 + DynamoDB)

Remote state is **not in git**. Bootstrap creates:

| Resource | Default name |
| --- | --- |
| S3 bucket (versioned, SSE-S3, public access blocked) | `vaathi-dev-tfstate` |
| DynamoDB lock table (`LockID`) | `vaathi-dev-tf-locks` |
| State object key (main stack) | `vaathi-dev/terraform.tfstate` |
| Region | `eu-west-2` |

Bootstrap uses **local state** once under `bootstrap/` (gitignored `*.tfstate*`). See [`bootstrap/README.md`](./bootstrap/README.md).

### 0) Bootstrap state backend

```bash
cd ~/vaathi-dev-infra
export AWS_PROFILE=hait   # H&A account

cd bootstrap
terraform init
terraform apply
cd ..

terraform -chdir=bootstrap output -raw backend_hcl_snippet > backend.hcl   # gitignored
```

### 1) Init main stack against remote state

```bash
cd ~/vaathi-dev-infra
export AWS_PROFILE=hait
terraform init -backend-config=backend.hcl
# If you had a previous local terraform.tfstate, answer yes to migrate.
```

### 2) Site apply order (DNS-aware)

ACM DNS validation is checked on **public** DNS. Create the hosted zone first, point GoDaddy at the NS, then finish the stack.

```bash
cp terraform.tfvars.example terraform.tfvars   # edit if needed

# Hosted zone only → copy NS to GoDaddy
terraform apply -target=aws_route53_zone.site
terraform output route53_name_servers
# GoDaddy → nameservers → paste the 4 AWS NS values; wait for dig NS vaathi.dev

# Full site stack (ACM, CloudFront, site S3, OIDC role, …)
terraform apply
```

If the account already has `token.actions.githubusercontent.com` OIDC provider:

```hcl
# terraform.tfvars
create_github_oidc_provider = false
github_oidc_provider_arn    = "arn:aws:iam::ACCOUNT:oidc-provider/token.actions.githubusercontent.com"
```

## Outputs → GitHub Actions (app repo)

After site apply:

```bash
terraform output -json github_actions_vars
```

In **app** repo → Settings → Secrets and variables → Actions → **Variables**:

| Variable | From output |
| --- | --- |
| `AWS_REGION` | `aws_region` (e.g. `eu-west-2`) |
| `AWS_DEPLOY_ROLE_ARN` | `github_deploy_role_arn` |
| `AWS_S3_BUCKET` | `site_bucket_name` |
| `AWS_CLOUDFRONT_DISTRIBUTION_ID` | `cloudfront_distribution_id` |

## GoDaddy checklist

1. Apply targeted zone; note `route53_name_servers`.
2. GoDaddy → domain `vaathi.dev` → nameservers → replace with the four AWS values.
3. Wait for NS propagation.
4. `terraform apply` (full site).
5. Smoke: `https://vaathi.dev`, `https://www.vaathi.dev` (301 to apex).

## GitHub

- **Repo:** https://github.com/hait-ashok/vaathi-dev-infra
- **App repo:** https://github.com/hait-ashok/vaathi.dev
- **Project:** https://github.com/users/hait-ashok/projects/1
