#!/usr/bin/env bash
# Deploy Sandbox Lambda (Bedrock + Cognito JWT gate) — AWS network only.
set -euo pipefail
export AWS_PROFILE="${AWS_PROFILE:-hait}"
REGION_SITE="${REGION_SITE:-eu-west-2}"
REGION_BEDROCK="${REGION_BEDROCK:-eu-west-1}"
ACCOUNT="$(aws sts get-caller-identity --query Account --output text)"
FN_NAME="vaathi-sandbox"
ROLE_NAME="vaathi-sandbox-lambda"
TABLE="vaathi-sandbox-ledger"
MODEL_ID="eu.amazon.nova-micro-v1:0"
DIR="$(cd "$(dirname "$0")" && pwd)"
COGNITO_JSON="${DIR}/../../cognito/cognito-outputs.json"

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
      "Sid": "CognitoGetUser",
      "Effect": "Allow",
      "Action": ["cognito-idp:GetUser"],
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
    "DAILY_CAP_USD": "1.0",
    "REQUIRE_AUTH": "true",
    "COGNITO_REGION": "${COGNITO_REGION}",
    "COGNITO_USER_POOL_ID": "${COGNITO_POOL_ID}",
    "ALLOWED_ORIGINS": "https://vaathi.dev|https://www.vaathi.dev|http://127.0.0.1:4321|http://localhost:4321"
  }
}
EOF

if aws lambda get-function --function-name "$FN_NAME" --region "$REGION_SITE" &>/dev/null; then
  aws lambda update-function-code --function-name "$FN_NAME" --region "$REGION_SITE" \
    --zip-file fileb:///tmp/vaathi-sandbox.zip >/dev/null
  aws lambda wait function-updated --function-name "$FN_NAME" --region "$REGION_SITE"
  aws lambda update-function-configuration --function-name "$FN_NAME" --region "$REGION_SITE" \
    --timeout 60 --memory-size 256 --environment file:///tmp/vaathi-sandbox-env.json >/dev/null
  aws lambda wait function-updated --function-name "$FN_NAME" --region "$REGION_SITE"
else
  aws lambda create-function --function-name "$FN_NAME" --region "$REGION_SITE" \
    --runtime python3.12 --handler handler.handler --role "$ROLE_ARN" \
    --zip-file fileb:///tmp/vaathi-sandbox.zip --timeout 60 --memory-size 256 \
    --environment file:///tmp/vaathi-sandbox-env.json \
    --tags Project=vaathi-practice >/dev/null
  aws lambda wait function-active --function-name "$FN_NAME" --region "$REGION_SITE"
fi

# Function URL CORS — allow Authorization for Cognito bearer tokens
CORS='AllowOrigins=https://vaathi.dev,https://www.vaathi.dev,http://127.0.0.1:4321,http://localhost:4321,AllowMethods=POST,AllowHeaders=content-type,authorization,MaxAge=86400'
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

URL="$(aws lambda get-function-url-config --function-name "$FN_NAME" --region "$REGION_SITE" --query FunctionUrl --output text)"
echo "FUNCTION_URL=$URL"
echo "COGNITO_POOL=$COGNITO_POOL_ID"
echo "$URL" > /tmp/vaathi-sandbox-url.txt
