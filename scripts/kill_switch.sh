#!/usr/bin/env bash

set -euo pipefail

# ==============================================================
# CloudHub 2.0 - Emergency Ingress Kill Switch
# ==============================================================

ANYPOINT_HOST="anypoint.mulesoft.com"

ANYPOINT_USERNAME="${ANYPOINT_USERNAME:?Set ANYPOINT_USERNAME}"
ANYPOINT_PASSWORD="${ANYPOINT_PASSWORD:?Set ANYPOINT_PASSWORD}"
ANYPOINT_ORG_ID="${ANYPOINT_ORG_ID:?Set ANYPOINT_ORG_ID}"
ANYPOINT_PRIVATE_SPACE_ID="${ANYPOINT_PRIVATE_SPACE_ID:?Set ANYPOINT_PRIVATE_SPACE_ID}"

PS_URL="https://${ANYPOINT_HOST}/runtimefabric/api/organizations/${ANYPOINT_ORG_ID}/privatespaces/${ANYPOINT_PRIVATE_SPACE_ID}"

echo "==> [1/4] Authenticating with Anypoint Platform..."

TOKEN_RESPONSE=$(curl -sS -X POST \
  "https://${ANYPOINT_HOST}/accounts/login" \
  -H "Content-Type: application/json" \
  -d "{
    \"username\": \"${ANYPOINT_USERNAME}\",
    \"password\": \"${ANYPOINT_PASSWORD}\",
    \"grant_type\": \"password\"
  }")

TOKEN=$(echo "${TOKEN_RESPONSE}" | jq -r '.access_token // empty')

if [[ -z "${TOKEN}" ]]; then
  echo "ERROR: Failed to retrieve access token."
  echo "${TOKEN_RESPONSE}" | jq . 2>/dev/null || echo "${TOKEN_RESPONSE}"
  exit 1
fi

echo "Token acquired successfully."

echo "==> [2/4] Fetching Private Space configuration..."

PS_CONFIG=$(curl -sS -X GET \
  "${PS_URL}" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json")

if [[ -z "${PS_CONFIG}" ]]; then
  echo "ERROR: Empty response from Private Space API."
  exit 1
fi

echo "Private Space configuration retrieved."

echo "==> [3/4] Backing up firewall rules..."

echo "${PS_CONFIG}" |
  jq '{managedFirewallRules: .managedFirewallRules}' \
  > firewall_backup.json

echo "Backup saved to firewall_backup.json"

echo "==> Building kill-switch payload..."

UPDATED_PAYLOAD=$(
  echo "${PS_CONFIG}" |
  jq '{
    managedFirewallRules:
      [.managedFirewallRules[]
       | select(.type == "outbound")]
  }'
)

echo "Payload:"
echo "${UPDATED_PAYLOAD}" | jq .

echo "==> [4/4] Applying PATCH..."

RESPONSE=$(curl -sS \
  -w "\n%{http_code}" \
  -X PATCH \
  "${PS_URL}" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json;charset=UTF-8" \
  --data-raw "${UPDATED_PAYLOAD}")

HTTP_BODY=$(echo "${RESPONSE}" | sed '$d')
HTTP_CODE=$(echo "${RESPONSE}" | tail -n 1)

echo "HTTP Status: ${HTTP_CODE}"
echo "Response:"

echo "${HTTP_BODY}" |
  jq . 2>/dev/null ||
  echo "${HTTP_BODY}"

if [[ "${HTTP_CODE}" == "200" ]]; then
  echo "KILL SWITCH ENGAGED"
  echo "Inbound rules removed; outbound rules preserved."
else
  echo "Kill switch failed."
  exit 1
fi
