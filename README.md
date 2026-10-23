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
- GitHub app repo (default trust: immutable OIDC sub for `hait-ashok/vaathi.dev` on `main`, with owner/repo numeric IDs)

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

# backend.hcl is committed for CI; regenerate from bootstrap if names change:
# terraform -chdir=bootstrap output -raw backend_hcl_snippet > backend.hcl
```

### 1) Init main stack against remote state

```bash
cd ~/vaathi-dev-infra
export AWS_PROFILE=hait
terraform init -backend-config=backend.hcl
# If you had a previous local terraform.tfstate, answer yes to migrate.
```

### 2) Site apply order (DNS-aware)

ACM DNS validation is checked on **public** DNS. Zone + ACM validation records can exist first; **CloudFront waits until GoDaddy points NS at Route 53**.

```bash
cp terraform.tfvars.example terraform.tfvars   # includes existing OIDC provider ARN for H&A account

# Prefer native darwin_arm64 terraform on Apple Silicon (Rosetta x86 provider can time out)
terraform apply -target=aws_route53_zone.site
terraform output route53_name_servers
# → GoDaddy custom nameservers (see Project store docs/go-live-outputs.md)
# Wait: dig NS vaathi.dev +short

# Finish ACM validation + CloudFront + aliases + bucket/role policies
terraform apply -auto-approve
terraform output -json github_actions_vars
```

**Partial apply (2026-10-22):** zone, site bucket, ACM (PENDING_VALIDATION), deploy role, CF function/OAC/headers are live. Re-run `terraform apply` after NS cutover.

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

## Terraform CI (Phase B — plan + gated apply)

GitHub Actions workflow [`.github/workflows/terraform.yml`](./.github/workflows/terraform.yml):

- **PR → `main`:** `fmt` → `validate` → `plan` → PR comment + artifact
- **Push → `main` / `workflow_dispatch`:** Apply job behind Environment **`terraform`** (required reviewers). After H&A **approves the Environment deployment** in the Actions run, CI re-plans and `terraform apply`s that plan.
- **Auth:** OIDC role `vaathi-dev-github-terraform` (not the app deploy role)
- **Backend:** committed [`backend.hcl`](./backend.hcl) (bucket/key/table names only)
- **Local apply** still available with `AWS_PROFILE=hait` for destroy / one-offs / timing-sensitive DNS

Infra repo → Settings → Secrets and variables → Actions → **Variables**:

| Variable | Value |
| --- | --- |
| `AWS_REGION` | `eu-west-2` |
| `AWS_TERRAFORM_ROLE_ARN` | `terraform output -raw github_terraform_role_arn` |

Environment **`terraform`**: required reviewer `hait-ashok`; deployment branches = `main` only.  
Settings → Environments → [terraform](https://github.com/hait-ashok/vaathi-dev-infra/settings/environments).

Fork PRs skip AWS. Terraform pin: **1.5.7**. Concurrency group `terraform-prod` with `cancel-in-progress: false` (do not cancel mid-apply).

## GitHub

- **Repo:** https://github.com/hait-ashok/vaathi-dev-infra
- **App repo:** https://github.com/hait-ashok/vaathi.dev
- **Project:** https://github.com/users/hait-ashok/projects/1
