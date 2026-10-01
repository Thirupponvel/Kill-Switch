#!/usr/bin/env bash

set -euo pipefail

# ==============================================================
# CloudHub 2.0 - Firewall Control
# Normal / Kill-Switch
# ==============================================================

ANYPOINT_HOST="anypoint.mulesoft.com"

# ==============================================================
# Required Environment Variables
# ==============================================================

ANYPOINT_CLIENT_ID="${ANYPOINT_CLIENT_ID:?ERROR: ANYPOINT_CLIENT_ID is not set}"
ANYPOINT_CLIENT_SECRET="${ANYPOINT_CLIENT_SECRET:?ERROR: ANYPOINT_CLIENT_SECRET is not set}"
ANYPOINT_ORG_ID="${ANYPOINT_ORG_ID:?ERROR: ANYPOINT_ORG_ID is not set}"
ANYPOINT_PRIVATE_SPACE_ID="${ANYPOINT_PRIVATE_SPACE_ID:?ERROR: ANYPOINT_PRIVATE_SPACE_ID is not set}"

NORMAL_FIREWALL_JSON="${NORMAL_FIREWALL_JSON:?ERROR: NORMAL_FIREWALL_JSON is not set}"
KILL_SWITCH_FIREWALL_JSON="${KILL_SWITCH_FIREWALL_JSON:?ERROR: KILL_SWITCH_FIREWALL_JSON is not set}"

# ==============================================================
# Input
# ==============================================================

MODE="${1:-}"

if [[ "${MODE}" != "normal" && "${MODE}" != "kill-switch" ]]; then

    echo ""
    echo "ERROR: Invalid mode."
    echo ""
    echo "Usage:"
    echo "  ./cloudhub_firewall_control.sh normal"
    echo "  ./cloudhub_firewall_control.sh kill-switch"
    echo ""

    exit 1
fi

# ==============================================================
# Paths
# ==============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

BACKUP_DIR="${PROJECT_DIR}/backups"

PS_URL="https://${ANYPOINT_HOST}/runtimefabric/api/organizations/${ANYPOINT_ORG_ID}/privatespaces/${ANYPOINT_PRIVATE_SPACE_ID}"

# ==============================================================
# Create backup directory only for Kill-Switch
# ==============================================================

if [[ "${MODE}" == "kill-switch" ]]; then
    mkdir -p "${BACKUP_DIR}"
fi

# ==============================================================
# Header
# ==============================================================

echo ""
echo "=============================================================="
echo " CloudHub 2.0 - Firewall Control"
echo "=============================================================="
echo " Mode: ${MODE}"
echo "=============================================================="
echo ""

# ==============================================================
# 1. Authenticate using Connected App
# ==============================================================

echo "==> [1/5] Authenticating using Anypoint Connected App..."

TOKEN_RESPONSE=$(curl -sS \
    -X POST \
    "https://${ANYPOINT_HOST}/accounts/api/v2/oauth2/token" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    --data-urlencode "client_id=${ANYPOINT_CLIENT_ID}" \
    --data-urlencode "client_secret=${ANYPOINT_CLIENT_SECRET}" \
    --data-urlencode "grant_type=client_credentials")

TOKEN=$(echo "${TOKEN_RESPONSE}" | jq -r '.access_token // empty')

if [[ -z "${TOKEN}" ]]; then

    echo ""
    echo "ERROR: Failed to retrieve access token."
    echo "Connected App authentication failed."

    exit 1
fi

echo "Connected App authentication successful."

# ==============================================================
# 2. Get Current Private Space Configuration
# ==============================================================

echo ""
echo "==> [2/5] Fetching current Private Space configuration..."

PS_CONFIG=$(curl -sS \
    -X GET \
    "${PS_URL}" \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Content-Type: application/json")

if [[ -z "${PS_CONFIG}" ]]; then

    echo ""
    echo "ERROR: Empty response from Private Space API."

    exit 1
fi

# Validate JSON

if ! echo "${PS_CONFIG}" | jq empty >/dev/null 2>&1; then

    echo ""
    echo "ERROR: Private Space API returned invalid JSON."

    exit 1
fi

echo "Private Space configuration retrieved successfully."

# ==============================================================
# 3. Backup Current Firewall
#    ONLY FOR KILL-SWITCH
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

        echo ""
        echo "ERROR: Backup file was not created."

        exit 1
    fi

    if ! jq empty "${BACKUP_FILE}" >/dev/null 2>&1; then

        echo ""
        echo "ERROR: Backup JSON is invalid."

        exit 1
    fi

    echo "Firewall backup successfully created."

else

    echo ""
    echo "==> [3/5] NORMAL mode detected."
    echo "==> Backup is NOT required."

fi

# ==============================================================
# 4. Select Firewall Configuration
# ==============================================================

echo ""
echo "==> [4/5] Selecting firewall configuration..."

if [[ "${MODE}" == "normal" ]]; then

    FIREWALL_JSON="${NORMAL_FIREWALL_JSON}"

    echo "Selected configuration: NORMAL"

else

    FIREWALL_JSON="${KILL_SWITCH_FIREWALL_JSON}"

    echo "Selected configuration: KILL-SWITCH"

fi

# ==============================================================
# Validate Firewall JSON
# ==============================================================

if ! echo "${FIREWALL_JSON}" | jq empty >/dev/null 2>&1; then

    echo ""
    echo "ERROR: Firewall configuration contains invalid JSON."

    exit 1
fi

echo "Firewall configuration validated successfully."

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
    --data-raw "${FIREWALL_JSON}")

HTTP_BODY=$(echo "${HTTP_RESPONSE}" | sed '$d')
HTTP_CODE=$(echo "${HTTP_RESPONSE}" | tail -n 1)

echo ""
echo "API request completed."
echo "HTTP Status: ${HTTP_CODE}"

# ==============================================================
# Result
# ==============================================================

if [[ "${HTTP_CODE}" =~ ^2[0-9][0-9]$ ]]; then

    # ----------------------------------------------------------
    # Kill-Switch Success
    # ----------------------------------------------------------

    if [[ "${MODE}" == "kill-switch" ]]; then

        echo ""
        echo "=============================================================="
        echo " KILL SWITCH SUCCESSFULLY ENGAGED"
        echo "=============================================================="
        echo ""
        echo "Pre-kill-switch firewall backup created successfully."
        echo ""

    # ----------------------------------------------------------
    # Normal Success
    # ----------------------------------------------------------

    else

        echo ""
        echo "=============================================================="
        echo " NORMAL FIREWALL CONFIGURATION RESTORED"
        echo "=============================================================="
        echo ""

    fi

else

    # ----------------------------------------------------------
    # PATCH Failed
    # ----------------------------------------------------------

    echo ""
    echo "=============================================================="
    echo " FIREWALL UPDATE FAILED"
    echo "=============================================================="
    echo ""
    echo "HTTP Status: ${HTTP_CODE}"

    # Preserve backup if Kill-Switch failed

    if [[ "${MODE}" == "kill-switch" ]]; then

        echo ""
        echo "IMPORTANT:"
        echo "The pre-kill-switch firewall backup has been preserved."

    fi

    exit 1

fi
