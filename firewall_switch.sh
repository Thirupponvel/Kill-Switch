#!/usr/bin/env bash

set -euo pipefail

# ==============================================================
# CloudHub 2.0 - Firewall Normal / Kill Switch
# ==============================================================

ANYPOINT_HOST="anypoint.mulesoft.com"

# --------------------------------------------------------------
# Required environment variables
# --------------------------------------------------------------

ANYPOINT_USERNAME="${ANYPOINT_USERNAME:?ERROR: Set ANYPOINT_USERNAME}"
ANYPOINT_PASSWORD="${ANYPOINT_PASSWORD:?ERROR: Set ANYPOINT_PASSWORD}"
ANYPOINT_ORG_ID="${ANYPOINT_ORG_ID:?ERROR: Set ANYPOINT_ORG_ID}"
ANYPOINT_PRIVATE_SPACE_ID="${ANYPOINT_PRIVATE_SPACE_ID:?ERROR: Set ANYPOINT_PRIVATE_SPACE_ID}"

# --------------------------------------------------------------
# Input
# --------------------------------------------------------------

MODE="${1:-}"

if [[ "${MODE}" != "normal" && "${MODE}" != "kill-switch" ]]; then
    echo ""
    echo "ERROR: Invalid mode."
    echo ""
    echo "Usage:"
    echo "  ./firewall_switch.sh normal"
    echo "  ./firewall_switch.sh kill-switch"
    echo ""
    exit 1
fi

# --------------------------------------------------------------
# Paths
# --------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

CONFIG_DIR="${PROJECT_DIR}/config"
BACKUP_DIR="${PROJECT_DIR}/backups"

NORMAL_FILE="${CONFIG_DIR}/normal-firewall.json"
KILL_SWITCH_FILE="${CONFIG_DIR}/kill-switch-firewall.json"

PS_URL="https://${ANYPOINT_HOST}/runtimefabric/api/organizations/${ANYPOINT_ORG_ID}/privatespaces/${ANYPOINT_PRIVATE_SPACE_ID}"

# Create backup directory only when required.
if [[ "${MODE}" == "kill-switch" ]]; then
    mkdir -p "${BACKUP_DIR}"
fi

echo ""
echo "=============================================================="
echo " CloudHub 2.0 - Firewall Control"
echo "=============================================================="
echo " Mode             : ${MODE}"
echo " Organization ID : ${ANYPOINT_ORG_ID}"
echo " Private Space ID: ${ANYPOINT_PRIVATE_SPACE_ID}"
echo "=============================================================="
echo ""

# ==============================================================
# 1. Authenticate
# ==============================================================

echo "==> [1/5] Authenticating with Anypoint Platform..."

TOKEN_RESPONSE=$(curl -sS \
    -X POST \
    "https://${ANYPOINT_HOST}/accounts/login" \
    -H "Content-Type: application/json" \
    -d "{
        \"username\": \"${ANYPOINT_USERNAME}\",
        \"password\": \"${ANYPOINT_PASSWORD}\",
        \"grant_type\": \"password\"
    }")

TOKEN=$(echo "${TOKEN_RESPONSE}" | jq -r '.access_token // empty')

if [[ -z "${TOKEN}" ]]; then
    echo ""
    echo "ERROR: Failed to retrieve access token."
    echo "Authentication response:"

    echo "${TOKEN_RESPONSE}" |
        jq . 2>/dev/null ||
        echo "${TOKEN_RESPONSE}"

    exit 1
fi

echo "Authentication successful."

# ==============================================================
# 2. Get current Private Space configuration
# ==============================================================

echo ""
echo "==> [2/5] Fetching current Private Space configuration..."

PS_CONFIG=$(curl -sS \
    -X GET \
    "${PS_URL}" \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Content-Type: application/json")

if [[ -z "${PS_CONFIG}" ]]; then
    echo "ERROR: Empty response from Private Space API."
    exit 1
fi

# Validate JSON response

if ! echo "${PS_CONFIG}" | jq empty >/dev/null 2>&1; then
    echo "ERROR: Private Space API returned invalid JSON."
    echo "${PS_CONFIG}"
    exit 1
fi

echo "Private Space configuration retrieved successfully."

# ==============================================================
# 3. Backup current firewall
#    ONLY for KILL-SWITCH
# ==============================================================

if [[ "${MODE}" == "kill-switch" ]]; then

    echo ""
    echo "==> [3/5] KILL-SWITCH mode detected."
    echo "==> Creating backup of current firewall rules..."

    TIMESTAMP=$(date -u +"%Y%m%d-%H%M%S")

    BACKUP_FILE="${BACKUP_DIR}/firewall-backup-${TIMESTAMP}.json"

    echo "${PS_CONFIG}" |
        jq '{
            managedFirewallRules: (.managedFirewallRules // [])
        }' > "${BACKUP_FILE}"

    # Validate backup

    if [[ ! -s "${BACKUP_FILE}" ]]; then
        echo "ERROR: Backup file was not created."
        exit 1
    fi

    echo "Backup successfully created:"
    echo "${BACKUP_FILE}"

else

    echo ""
    echo "==> [3/5] NORMAL mode detected."
    echo "==> Backup is NOT required."

fi

# ==============================================================
# 4. Select configuration
# ==============================================================

echo ""
echo "==> [4/5] Selecting firewall configuration..."

if [[ "${MODE}" == "normal" ]]; then

    CONFIG_FILE="${NORMAL_FILE}"

    echo "Selected configuration:"
    echo "${CONFIG_FILE}"

else

    CONFIG_FILE="${KILL_SWITCH_FILE}"

    echo "Selected configuration:"
    echo "${CONFIG_FILE}"

fi

# --------------------------------------------------------------
# Validate configuration file exists
# --------------------------------------------------------------

if [[ ! -f "${CONFIG_FILE}" ]]; then
    echo ""
    echo "ERROR: Configuration file not found:"
    echo "${CONFIG_FILE}"
    exit 1
fi

# --------------------------------------------------------------
# Validate configuration JSON
# --------------------------------------------------------------

if ! jq empty "${CONFIG_FILE}" >/dev/null 2>&1; then
    echo ""
    echo "ERROR: Invalid JSON configuration:"
    echo "${CONFIG_FILE}"
    exit 1
fi

echo "Configuration JSON is valid."

echo ""
echo "Desired firewall configuration:"
echo "--------------------------------------------------------------"

jq . "${CONFIG_FILE}"

echo "--------------------------------------------------------------"

# ==============================================================
# 5. PATCH Private Space
# ==============================================================

echo ""
echo "==> [5/5] Applying firewall configuration..."

HTTP_RESPONSE=$(curl -sS \
    -w "\n%{http_code}" \
    -X PATCH \
    "${PS_URL}" \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Content-Type: application/json;charset=UTF-8" \
    --data-binary "@${CONFIG_FILE}")

HTTP_BODY=$(echo "${HTTP_RESPONSE}" | sed '$d')
HTTP_CODE=$(echo "${HTTP_RESPONSE}" | tail -n 1)

echo ""
echo "HTTP Status: ${HTTP_CODE}"

echo ""
echo "API Response:"
echo "--------------------------------------------------------------"

if echo "${HTTP_BODY}" | jq . >/dev/null 2>&1; then
    echo "${HTTP_BODY}" | jq .
else
    echo "${HTTP_BODY}"
fi

echo "--------------------------------------------------------------"

# ==============================================================
# Result
# ==============================================================

if [[ "${HTTP_CODE}" =~ ^2[0-9][0-9]$ ]]; then

    if [[ "${MODE}" == "kill-switch" ]]; then

        echo ""
        echo "=============================================================="
        echo " KILL SWITCH SUCCESSFULLY ENGAGED"
        echo "=============================================================="
        echo ""
        echo "Backup:"
        echo "${BACKUP_FILE}"
        echo ""
        echo "Kill-switch configuration:"
        echo "${KILL_SWITCH_FILE}"
        echo ""

    else

        echo ""
        echo "=============================================================="
        echo " NORMAL FIREWALL CONFIGURATION RESTORED"
        echo "=============================================================="
        echo ""
        echo "Configuration:"
        echo "${NORMAL_FILE}"
        echo ""

    fi

else

    echo ""
    echo "=============================================================="
    echo " FIREWALL UPDATE FAILED"
    echo "=============================================================="
    echo ""
    echo "HTTP Status: ${HTTP_CODE}"
    echo ""

    # If kill-switch PATCH fails, backup is still preserved.
    if [[ "${MODE}" == "kill-switch" ]]; then
        echo "IMPORTANT:"
        echo "The pre-kill-switch firewall backup was preserved at:"
        echo "${BACKUP_FILE}"
    fi

    exit 1

fi
