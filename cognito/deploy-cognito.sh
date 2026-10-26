#!/usr/bin/env bash
# Create Cognito user pool for vaathi.dev Sandbox (email + required TOTP MFA).
set -euo pipefail
export AWS_PROFILE="${AWS_PROFILE:-hait}"
REGION="${REGION:-eu-west-2}"
POOL_NAME="vaathi-sandbox"
CLIENT_NAME="vaathi-sandbox-web"
OUT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "Region $REGION"

EXISTING="$(aws cognito-idp list-user-pools --max-results 60 --region "$REGION" \
  --query "UserPools[?Name=='${POOL_NAME}'].Id | [0]" --output text 2>/dev/null || true)"
if [[ "$EXISTING" != "None" && -n "$EXISTING" && "$EXISTING" != "null" ]]; then
  POOL_ID="$EXISTING"
  echo "Using existing pool $POOL_ID"
else
  POOL_ID="$(aws cognito-idp create-user-pool --region "$REGION" --pool-name "$POOL_NAME" \
    --policies 'PasswordPolicy={MinimumLength=10,RequireUppercase=true,RequireLowercase=true,RequireNumbers=true,RequireSymbols=false}' \
    --auto-verified-attributes email \
    --username-attributes email \
    --mfa-configuration "OFF" \
    --account-recovery-setting 'RecoveryMechanisms=[{Priority=1,Name=verified_email}]' \
    --schema Name=email,Required=true,Mutable=true \
    --user-pool-tags Project=vaathi-practice,ManagedBy=script \
    --query 'UserPool.Id' --output text)"
  echo "Created pool $POOL_ID"
fi

# Require authenticator-app MFA (TOTP) — no SMS
aws cognito-idp set-user-pool-mfa-config --region "$REGION" --user-pool-id "$POOL_ID" \
  --mfa-configuration "ON" \
  --software-token-mfa-configuration Enabled=true

CLIENT_ID="$(aws cognito-idp list-user-pool-clients --region "$REGION" --user-pool-id "$POOL_ID" --max-results 60 \
  --query "UserPoolClients[?ClientName=='${CLIENT_NAME}'].ClientId | [0]" --output text)"
if [[ "$CLIENT_ID" == "None" || -z "$CLIENT_ID" || "$CLIENT_ID" == "null" ]]; then
  CLIENT_ID="$(aws cognito-idp create-user-pool-client --region "$REGION" --user-pool-id "$POOL_ID" \
    --client-name "$CLIENT_NAME" \
    --no-generate-secret \
    --explicit-auth-flows ALLOW_USER_PASSWORD_AUTH ALLOW_REFRESH_TOKEN_AUTH ALLOW_USER_SRP_AUTH \
    --prevent-user-existence-errors ENABLED \
    --enable-token-revocation \
    --access-token-validity 60 --id-token-validity 60 --refresh-token-validity 7 \
    --token-validity-units AccessToken=minutes,IdToken=minutes,RefreshToken=days \
    --supported-identity-providers COGNITO \
    --query 'UserPoolClient.ClientId' --output text)"
  echo "Created client $CLIENT_ID"
else
  echo "Using existing client $CLIENT_ID"
fi

cat >"$OUT_DIR/cognito-outputs.json" <<EOF
{
  "region": "${REGION}",
  "userPoolId": "${POOL_ID}",
  "clientId": "${CLIENT_ID}",
  "cognitoIdpEndpoint": "https://cognito-idp.${REGION}.amazonaws.com/"
}
EOF
echo "Wrote $OUT_DIR/cognito-outputs.json"
cat "$OUT_DIR/cognito-outputs.json"
