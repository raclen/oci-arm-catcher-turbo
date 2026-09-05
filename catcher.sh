#!/usr/bin/env bash

# ==============================================================================
# Oracle Cloud ARM Instance Capacity Catcher
#
# Features:
# 1. Zero-dependency core: official OCI CLI + bash + jq + python3 (standard lib).
# 2. --no-retry flag to avoid SDK internal blocking backoffs.
# 3. Automatic Availability Domain (AD) polling & rotation.
# 4. Instant one-shot termination on success (strictly zero extra charges).
# 5. Fast fatal error detection (stops immediately on invalid OCID/auth errors).
# 6. Automatic public IP query and ServerChan (微信推送) integration.
# ==============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ ! -f "$SCRIPT_DIR/.env" ]; then
    echo "[ERROR] .env file not found! Please copy .env.example to .env and configure it."
    exit 1
fi

source "$SCRIPT_DIR/.env"

export PATH="$HOME/bin:$PATH"
export SUPPRESS_LABEL_WARNING="${SUPPRESS_LABEL_WARNING:-True}"

LOG_FILE="$SCRIPT_DIR/catcher.log"

log() {
    echo "[$(date '+%F %T')] $*" | tee -a "$LOG_FILE"
}

send_notify() {
    local title="$1"
    local desp="$2"
    if [ -n "${SERVERCHAN_SENDKEY:-}" ]; then
        log "Sending notification via ServerChan..."
        python3 - << PYEOF
import os, urllib.request, urllib.parse

sendkey = os.environ.get("SERVERCHAN_SENDKEY", "")
if not sendkey:
    exit(0)

title = """$title"""
desp = """$desp"""

url = f"https://sctapi.ftqq.com/{sendkey}.send"
data = urllib.parse.urlencode({'title': title, 'desp': desp}).encode('utf-8')
req = urllib.request.Request(url, data=data, headers={'Content-Type': 'application/x-www-form-urlencoded; charset=utf-8'})

try:
    with urllib.request.urlopen(req, timeout=15) as resp:
        pass
except Exception as e:
    print(f"ServerChan Notify Error: {e}")
PYEOF
    fi
}

export SERVERCHAN_SENDKEY

log "=========================================="
log "Oracle ARM Catcher started"
log "Shape: VM.Standard.A1.Flex"
log "OCPU: $OCPUS"
log "Memory: ${MEMORY_GB}GB"
log "=========================================="

# Check OCI CLI
if ! command -v oci >/dev/null 2>&1; then
    log "ERROR: OCI CLI not found. Please install OCI CLI first."
    exit 1
fi

# Check jq
if ! command -v jq >/dev/null 2>&1; then
    log "ERROR: jq not found. Please run 'sudo apt-get install -y jq' first."
    exit 1
fi

# Check SSH Public Key
if [ ! -f "$SSH_KEY_FILE" ]; then
    log "ERROR: SSH public key not found: $SSH_KEY_FILE"
    exit 1
fi

# Fetch Availability Domains (ADs)
mapfile -t ADS < <(
    oci iam availability-domain list | jq -r '.data[].name'
)

if [ "${#ADS[@]}" -eq 0 ]; then
    log "ERROR: Cannot get Availability Domains. Check ~/.oci/config credentials."
    exit 1
fi

log "Available ADs:"
for AD in "${ADS[@]}"; do
    log " - $AD"
done

AD_INDEX=0

while true; do

    AD="${ADS[$AD_INDEX]}"

    log "Trying AD: $AD"

    RESPONSE=$(
        oci compute instance launch \
            --compartment-id "$COMPARTMENT_ID" \
            --availability-domain "$AD" \
            --shape "VM.Standard.A1.Flex" \
            --shape-config "{\"ocpus\": $OCPUS, \"memoryInGBs\": $MEMORY_GB}" \
            --display-name "$INSTANCE_NAME" \
            --image-id "$IMAGE_ID" \
            --subnet-id "$SUBNET_ID" \
            --assign-public-ip true \
            --ssh-authorized-keys-file "$SSH_KEY_FILE" \
            --no-retry \
            --connection-timeout 30 \
            --read-timeout 60 \
            2>&1
    )

    EXIT_CODE=$?

    if [ "$EXIT_CODE" -eq 0 ]; then

        INSTANCE_ID=$(echo "$RESPONSE" | jq -r '.data.id // empty')

        log "=========================================="
        log "SUCCESS!"
        log "ARM instance created successfully!"
        log "Instance OCID: $INSTANCE_ID"
        log "AD: $AD"
        log "=========================================="

        echo "$RESPONSE" > "$SCRIPT_DIR/success.json"

        # Query assigned public IP
        PUBLIC_IP="Fetching / Check OCI Console"
        if [ -n "$INSTANCE_ID" ]; then
            sleep 10
            FETCHED_IP=$(oci compute instance list-vnics --instance-id "$INSTANCE_ID" 2>/dev/null | jq -r '.data[0]."public-ip" // empty')
            if [ -n "$FETCHED_IP" ]; then
                PUBLIC_IP="$FETCHED_IP"
            fi
        fi

        NOTIFY_TITLE="🎉 甲骨文 ARM 抢机成功！"
        NOTIFY_BODY="### 恭喜！Oracle ARM 实例已创建成功！\n\n- **实例名称**: $INSTANCE_NAME\n- **规格**: ${OCPUS} OCPU / ${MEMORY_GB} GB 内存 (VM.Standard.A1.Flex)\n- **公网 IP**: \`$PUBLIC_IP\`\n- **可用区 (AD)**: $AD\n- **实例 OCID**: \`$INSTANCE_ID\`\n\n抢机守护脚本已自动退出，绝无重复开机扣费！"

        send_notify "$NOTIFY_TITLE" "$NOTIFY_BODY"

        exit 0
    fi

    log "Failed response:"
    log "$RESPONSE"

    # Stop immediately on irreversible errors (quota/permission/parameter bugs)
    if echo "$RESPONSE" | grep -qiE \
        "NotAuthorized|NotAuthenticated|InvalidParameter|Invalid.*OCID|CannotParse|Missing.*Parameter|Unauthorized"; then

        log "FATAL ERROR detected. Stopping to avoid infinite retry loops."
        exit 1
    fi

    # Rotate to next AD
    AD_INDEX=$(( (AD_INDEX + 1) % ${#ADS[@]} ))

    # Random wait between RETRY_MIN and RETRY_MAX
    WAIT=$(( RETRY_MIN + RANDOM % (RETRY_MAX - RETRY_MIN + 1) ))

    log "Out of host capacity or AD busy. Retrying after ${WAIT}s..."

    sleep "$WAIT"

done
