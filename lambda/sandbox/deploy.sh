#!/usr/bin/env bash
# Deploy Sandbox Lambda (Bedrock + Cognito + access allowlist) — AWS network only.
set -euo pipefail
export AWS_PROFILE="${AWS_PROFILE:-hait}"
REGION_SITE="${REGION_SITE:-eu-west-2}"
REGION_BEDROCK="${REGION_BEDROCK:-eu-west-1}"
ACCOUNT="$(aws sts get-caller-identity --query Account --output text)"
FN_NAME="vaathi-sandbox"
PRESIGNUP_FN="vaathi-sandbox-presignup"
ROLE_NAME="vaathi-sandbox-lambda"
TABLE="vaathi-sandbox-ledger"
ACCESS_TABLE="vaathi-sandbox-access"
ADMIN_GROUP="sandbox-admin"
MODEL_ID="eu.amazon.nova-micro-v1:0"
DIR="$(cd "$(dirname "$0")" && pwd)"
COGNITO_JSON="${DIR}/../../cognito/cognito-outputs.json"
# Set SANDBOX_ADMIN_EMAIL before deploy to grant /sandbox/admin (Cognito + TOTP).
SANDBOX_ADMIN_EMAIL="${SANDBOX_ADMIN_EMAIL:-}"

echo "Account $ACCOUNT · Lambda in $REGION_SITE · Bedrock $REGION_BEDROCK"

if [[ ! -f "$COGNITO_JSON" ]]; then
  echo "Missing $COGNITO_JSON — run cognito/deploy-cognito.sh first" >&2
  exit 1
fi
COGNITO_POOL_ID="$(/usr/bin/python3 -c "import json;print(json.load(open('$COGNITO_JSON'))['userPoolId'])")"
COGNITO_REGION="$(/usr/bin/python3 -c "import json;print(json.load(open('$COGNITO_JSON'))['region'])")"

# IAM role
if ! aws iam get-role --role-name "$ROLE_NAME" &>/dev/null; then
  aws iam create-role --role-name "$ROLE_NAME" \
    --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]}' \
    --tags Key=Project,Value=vaathi-practice >/dev/null
  aws iam attach-role-policy --role-name "$ROLE_NAME" \
    --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole
fi

cat >/tmp/vaathi-sandbox-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "BedrockConverse",
      "Effect": "Allow",
      "Action": [
        "bedrock:InvokeModel",
        "bedrock:InvokeModelWithResponseStream"
      ],
      "Resource": [
        "arn:aws:bedrock:${REGION_BEDROCK}::foundation-model/amazon.nova-micro-v1:0",
        "arn:aws:bedrock:${REGION_BEDROCK}:${ACCOUNT}:inference-profile/${MODEL_ID}",
        "arn:aws:bedrock:*::foundation-model/amazon.nova-micro-v1:0"
      ]
    },
    {
      "Sid": "Ledger",
      "Effect": "Allow",
      "Action": ["dynamodb:GetItem", "dynamodb:UpdateItem", "dynamodb:PutItem"],
      "Resource": "arn:aws:dynamodb:${REGION_SITE}:${ACCOUNT}:table/${TABLE}"
    },
    {
      "Sid": "AccessTable",
      "Effect": "Allow",
      "Action": [
        "dynamodb:GetItem",
        "dynamodb:UpdateItem",
        "dynamodb:PutItem",
        "dynamodb:Scan"
      ],
      "Resource": "arn:aws:dynamodb:${REGION_SITE}:${ACCOUNT}:table/${ACCESS_TABLE}"
    },
    {
      "Sid": "CognitoAuth",
      "Effect": "Allow",
      "Action": [
        "cognito-idp:GetUser",
        "cognito-idp:AdminListGroupsForUser",
        "cognito-idp:ListUsers"
      ],
      "Resource": "*"
    }
  ]
}
EOF
aws iam put-role-policy --role-name "$ROLE_NAME" --policy-name vaathi-sandbox-inline \
  --policy-document file:///tmp/vaathi-sandbox-policy.json

# DynamoDB ledger
if ! aws dynamodb describe-table --table-name "$TABLE" --region "$REGION_SITE" &>/dev/null; then
  aws dynamodb create-table --region "$REGION_SITE" --table-name "$TABLE" \
    --attribute-definitions AttributeName=pk,AttributeType=S \
    --key-schema AttributeName=pk,KeyType=HASH \
    --billing-mode PAY_PER_REQUEST \
    --tags Key=Project,Value=vaathi-practice >/dev/null
  aws dynamodb wait table-exists --table-name "$TABLE" --region "$REGION_SITE"
fi

# DynamoDB access allowlist / requests
if ! aws dynamodb describe-table --table-name "$ACCESS_TABLE" --region "$REGION_SITE" &>/dev/null; then
  aws dynamodb create-table --region "$REGION_SITE" --table-name "$ACCESS_TABLE" \
    --attribute-definitions AttributeName=email,AttributeType=S \
    --key-schema AttributeName=email,KeyType=HASH \
    --billing-mode PAY_PER_REQUEST \
    --tags Key=Project,Value=vaathi-practice >/dev/null
  aws dynamodb wait table-exists --table-name "$ACCESS_TABLE" --region "$REGION_SITE"
fi

ROLE_ARN="$(aws iam get-role --role-name "$ROLE_NAME" --query Role.Arn --output text)"
sleep 5

rm -f /tmp/vaathi-sandbox.zip
( cd "$DIR" && zip -q /tmp/vaathi-sandbox.zip handler.py )

cat >/tmp/vaathi-sandbox-env.json <<EOF
{
  "Variables": {
    "BEDROCK_REGION": "${REGION_BEDROCK}",
    "BEDROCK_MODEL_ID": "${MODEL_ID}",
    "LEDGER_TABLE": "${TABLE}",
    "ACCESS_TABLE": "${ACCESS_TABLE}",
    "ADMIN_GROUP": "${ADMIN_GROUP}",
    "DAILY_CAP_USD": "1.0",
    "REQUIRE_AUTH": "true",
    "COGNITO_REGION": "${COGNITO_REGION}",
    "COGNITO_USER_POOL_ID": "${COGNITO_POOL_ID}",
    "ALLOWED_ORIGINS": "https://vaathi.dev|https://www.vaathi.dev|http://127.0.0.1:4321|http://localhost:4321"
  }
}
EOF

deploy_or_update() {
  local name="$1"
  local handler_name="$2"
  if aws lambda get-function --function-name "$name" --region "$REGION_SITE" &>/dev/null; then
    aws lambda update-function-code --function-name "$name" --region "$REGION_SITE" \
      --zip-file fileb:///tmp/vaathi-sandbox.zip >/dev/null
    aws lambda wait function-updated --function-name "$name" --region "$REGION_SITE"
    aws lambda update-function-configuration --function-name "$name" --region "$REGION_SITE" \
      --timeout 60 --memory-size 256 --handler "$handler_name" \
      --environment file:///tmp/vaathi-sandbox-env.json >/dev/null
    aws lambda wait function-updated --function-name "$name" --region "$REGION_SITE"
  else
    aws lambda create-function --function-name "$name" --region "$REGION_SITE" \
      --runtime python3.12 --handler "$handler_name" --role "$ROLE_ARN" \
      --zip-file fileb:///tmp/vaathi-sandbox.zip --timeout 60 --memory-size 256 \
      --environment file:///tmp/vaathi-sandbox-env.json \
      --tags Project=vaathi-practice >/dev/null
    aws lambda wait function-active --function-name "$name" --region "$REGION_SITE"
  fi
}

deploy_or_update "$FN_NAME" "handler.handler"
deploy_or_update "$PRESIGNUP_FN" "handler.presignup"

PRESIGNUP_ARN="$(aws lambda get-function --function-name "$PRESIGNUP_FN" --region "$REGION_SITE" --query Configuration.FunctionArn --output text)"

# Cognito may invoke PreSignUp
aws lambda add-permission --function-name "$PRESIGNUP_FN" --region "$REGION_SITE" \
  --statement-id CognitoPreSignUp \
  --action lambda:InvokeFunction \
  --principal cognito-idp.amazonaws.com \
  --source-arn "arn:aws:cognito-idp:${COGNITO_REGION}:${ACCOUNT}:userpool/${COGNITO_POOL_ID}" \
  2>/dev/null || true

# Wire PreSignUp without wiping pool settings (UpdateUserPool resets omitted fields)
/usr/bin/python3 - <<PY
import json, subprocess
pool = "${COGNITO_POOL_ID}"
region = "${COGNITO_REGION}"
arn = "${PRESIGNUP_ARN}"
raw = subprocess.check_output([
    "aws", "cognito-idp", "describe-user-pool",
    "--region", region, "--user-pool-id", pool,
])
up = json.loads(raw)["UserPool"]
lc = dict(up.get("LambdaConfig") or {})
lc["PreSignUp"] = arn
args = [
    "aws", "cognito-idp", "update-user-pool",
    "--region", region, "--user-pool-id", pool,
    "--lambda-config", json.dumps(lc),
    "--auto-verified-attributes",
] + (up.get("AutoVerifiedAttributes") or ["email"])
if up.get("Policies"):
    args += ["--policies", json.dumps(up["Policies"])]
if up.get("MfaConfiguration"):
    args += ["--mfa-configuration", up["MfaConfiguration"]]
subprocess.check_call(args)
print("PreSignUp wired:", arn)
PY

# Re-assert TOTP MFA ON (separate API; UpdateUserPool can leave this inconsistent)
aws cognito-idp set-user-pool-mfa-config --region "$COGNITO_REGION" --user-pool-id "$COGNITO_POOL_ID" \
  --mfa-configuration "ON" \
  --software-token-mfa-configuration Enabled=true

# Function URL CORS — GET for admin list, POST for run + request + decide
CORS='AllowOrigins=https://vaathi.dev,https://www.vaathi.dev,http://127.0.0.1:4321,http://localhost:4321,AllowMethods=GET,POST,AllowHeaders=content-type,authorization,MaxAge=86400'
if ! aws lambda get-function-url-config --function-name "$FN_NAME" --region "$REGION_SITE" &>/dev/null; then
  aws lambda create-function-url-config --function-name "$FN_NAME" --region "$REGION_SITE" \
    --auth-type NONE --cors "$CORS" >/dev/null
else
  aws lambda update-function-url-config --function-name "$FN_NAME" --region "$REGION_SITE" \
    --cors "$CORS" >/dev/null
fi

aws lambda add-permission --function-name "$FN_NAME" --region "$REGION_SITE" \
  --statement-id FunctionURLAllowPublicAccess \
  --action lambda:InvokeFunctionUrl \
  --principal "*" \
  --function-url-auth-type NONE 2>/dev/null || true
aws lambda add-permission --function-name "$FN_NAME" --region "$REGION_SITE" \
  --statement-id FunctionURLAllowInvokeFunction \
  --action lambda:InvokeFunction \
  --principal "*" 2>/dev/null || true

# Cognito group for admin page
if ! aws cognito-idp get-group --region "$COGNITO_REGION" --user-pool-id "$COGNITO_POOL_ID" \
  --group-name "$ADMIN_GROUP" &>/dev/null; then
  aws cognito-idp create-group --region "$COGNITO_REGION" --user-pool-id "$COGNITO_POOL_ID" \
    --group-name "$ADMIN_GROUP" \
    --description "Can approve Sandbox access requests" >/dev/null
fi

# Seed: mark every existing Cognito user as approved (keep them signed-in capable)
echo "Seeding approved emails from Cognito users…"
/usr/bin/python3 - <<PY
import json, subprocess, time
pool = "${COGNITO_POOL_ID}"
region = "${COGNITO_REGION}"
table = "${ACCESS_TABLE}"
site = "${REGION_SITE}"
token = None
now = int(time.time())
while True:
    cmd = ["aws", "cognito-idp", "list-users", "--region", region, "--user-pool-id", pool, "--limit", "60"]
    if token:
        cmd += ["--pagination-token", token]
    raw = subprocess.check_output(cmd)
    data = json.loads(raw)
    for u in data.get("Users") or []:
        email = None
        for a in u.get("Attributes") or []:
            if a.get("Name") == "email":
                email = (a.get("Value") or "").strip().lower()
                break
        if not email:
            continue
        item = {
            "email": {"S": email},
            "status": {"S": "approved"},
            "requestedAt": {"N": str(now)},
            "decidedAt": {"N": str(now)},
            "decidedBy": {"S": "seed"},
            "updatedAt": {"N": str(now)},
            "note": {"S": "seeded from existing Cognito user"},
        }
        # Do not downgrade pending/denied — only put if missing or already approved
        get = subprocess.run(
            ["aws", "dynamodb", "get-item", "--region", site, "--table-name", table,
             "--key", json.dumps({"email": {"S": email}})],
            capture_output=True, text=True,
        )
        existing = json.loads(get.stdout or "{}").get("Item") or {}
        status = (existing.get("status") or {}).get("S")
        if status in ("pending", "denied"):
            continue
        subprocess.check_call(
            ["aws", "dynamodb", "put-item", "--region", site, "--table-name", table,
             "--item", json.dumps(item)]
        )
        print("approved", email)
    token = data.get("PaginationToken")
    if not token:
        break
PY

if [[ -n "$SANDBOX_ADMIN_EMAIL" ]]; then
  ADMIN_LC="$(echo "$SANDBOX_ADMIN_EMAIL" | tr '[:upper:]' '[:lower:]')"
  echo "Granting admin group to $ADMIN_LC"
  # Ensure allowlisted
  aws dynamodb put-item --region "$REGION_SITE" --table-name "$ACCESS_TABLE" --item "$(/usr/bin/python3 - <<PY
import json, time
print(json.dumps({
  "email": {"S": "${ADMIN_LC}"},
  "status": {"S": "approved"},
  "requestedAt": {"N": str(int(time.time()))},
  "decidedAt": {"N": str(int(time.time()))},
  "decidedBy": {"S": "deploy"},
  "updatedAt": {"N": str(int(time.time()))},
  "note": {"S": "sandbox admin"},
}))
PY
)" >/dev/null
  if aws cognito-idp admin-get-user --region "$COGNITO_REGION" --user-pool-id "$COGNITO_POOL_ID" \
    --username "$ADMIN_LC" &>/dev/null; then
    aws cognito-idp admin-add-user-to-group --region "$COGNITO_REGION" --user-pool-id "$COGNITO_POOL_ID" \
      --username "$ADMIN_LC" --group-name "$ADMIN_GROUP" >/dev/null
  else
    echo "WARN: Cognito user $ADMIN_LC not found — register/sign in first, then re-run with SANDBOX_ADMIN_EMAIL set." >&2
  fi
else
  echo "NOTE: SANDBOX_ADMIN_EMAIL unset — create Cognito user, then re-run:"
  echo "  SANDBOX_ADMIN_EMAIL=you@example.com $0"
fi

URL="$(aws lambda get-function-url-config --function-name "$FN_NAME" --region "$REGION_SITE" --query FunctionUrl --output text)"
echo "FUNCTION_URL=$URL"
echo "COGNITO_POOL=$COGNITO_POOL_ID"
echo "ACCESS_TABLE=$ACCESS_TABLE"
echo "PRESIGNUP=$PRESIGNUP_ARN"
echo "$URL" > /tmp/vaathi-sandbox-url.txt
