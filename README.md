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
- AWS credentials for the H&A account (`aws sts get-caller-identity` must work)
- GitHub app repo (default trust: `hait-ashok/vaathi.dev` on `main`)

## Apply order (important)

ACM DNS validation is checked on **public** DNS. Create the hosted zone first, point GoDaddy at the NS, then finish the stack.

```bash
cd ~/vaathi-dev-infra
cp terraform.tfvars.example terraform.tfvars   # edit if needed
terraform init

# 1) Hosted zone only → copy NS to GoDaddy
terraform apply -target=aws_route53_zone.site

terraform output route53_name_servers
# At GoDaddy: Domain → DNS / Nameservers → custom → paste the 4 AWS NS values
# Wait until dig NS vaathi.dev shows those servers (often 15–60+ minutes)

# 2) Full stack (ACM validation, CloudFront, S3, OIDC role, …)
terraform apply
```

**State:** default is **local** `terraform.tfstate` (fine for first apply — commit is gitignored; back up the file). Optional S3 backend: see `backend.hcl.example`, uncomment `backend "s3" {}` in `versions.tf`, then `terraform init -backend-config=backend.hcl`.

If the account already has `token.actions.githubusercontent.com` OIDC provider:

```hcl
create_github_oidc_provider = false
github_oidc_provider_arn    = "arn:aws:iam::ACCOUNT:oidc-provider/token.actions.githubusercontent.com"
```

## Outputs → GitHub Actions (app repo)

After apply:

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
2. GoDaddy → domain `vaathi.dev` → nameservers → replace with the four AWS values (not “forward only” records).
3. Wait for NS propagation.
4. `terraform apply` (full).
5. Smoke: `https://vaathi.dev`, `https://www.vaathi.dev` (should 301 to apex).

Do **not** leave apex A records at GoDaddy pointing elsewhere once NS are AWS — DNS is fully at Route 53 after cutover.

## GitHub remote (when ready)

```bash
# confirm login
gh api user --jq .login

gh repo create hait-ashok/vaathi-dev-infra --public --source=~/vaathi-dev-infra --remote=origin --push
```

Adjust owner if `gh api user` differs from `hait-ashok`.
