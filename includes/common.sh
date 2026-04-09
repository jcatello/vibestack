#!/bin/bash
# /opt/vibestack/includes/common.sh
# Vibestack Shared Functions & Configuration Loader

# --- CONFIG LOADER ---
# During vibestack-setup.sh the config file does not exist yet.
# We only fatal if we're NOT in setup context — setup writes the conf itself.
CONFIG_FILE="/opt/vibestack/config/vibestack.conf"
if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
else
    # Allow setup to proceed without a conf file.
    # Any API call (not setup) will hit fatal_error 2000 on verify_uid
    # since CONTAINER_NAME will be empty — safe fallback.
    SLACK_WEBHOOK_URL=""
    SLACK_TOKEN=""
    CONTAINER_NAME=""
    SERVICE_ID=""
    ZFS_NODE=""
    ZFS_LXD_BASE=""
fi

export SLACK_WEBHOOK_URL
export SLACK_TOKEN
export CONTAINER_NAME
export SERVICE_ID
export ZFS_NODE
export ZFS_LXD_BASE

# --- API RESPONSE FUNCTIONS ---

# Output a fatal error in Cloudflare JSON format and exit 1
# Usage: fatal_error <code> "message"
fatal_error() {
    local code=$1
    local msg=$2
    printf '{"success":false,"errors":[{"code":%s,"message":"%s"}],"messages":[],"result":null}\n' \
        "$code" "$msg"
    exit 1
}

# --- UID VERIFICATION ---
# Every API call must pass --uid matching this container's CONTAINER_NAME.
# Prevents WPO from accidentally firing commands at the wrong container.
# Usage: verify_uid <uid_from_api_call>
verify_uid() {
    local incoming_uid=$1

    if [[ -z "$incoming_uid" ]]; then
        fatal_error 2000 "Missing required parameter: --uid"
    fi

    if [[ -z "$CONTAINER_NAME" ]]; then
        fatal_error 2000 "Container UID not configured — vibestack.conf missing or incomplete"
    fi

    if [[ "$incoming_uid" != "$CONTAINER_NAME" ]]; then
        # Fire Slack alert — this should never happen in production
        local hostname
        hostname=$(hostname -f)
        THREAD_TS=$(send_slack_initial \
            "🚨 *UID MISMATCH* on \`${hostname}\` (service \`${SERVICE_ID}\`) — Expected: \`${CONTAINER_NAME}\` — Received: \`${incoming_uid}\`" \
            "alerts")
        send_slack_thread "$THREAD_TS" \
            "A WPO API call was rejected because the UID did not match the container. This may indicate a routing error in WPO." \
            "alerts"

        fatal_error 2001 "UID mismatch: expected ${CONTAINER_NAME}, received ${incoming_uid}"
    fi
}

# --- SLACK FUNCTIONS ---

# Send an initial Slack message, returns the message_id for threading
# Usage: THREAD_TS=$(send_slack_initial "message" "channel")
send_slack_initial() {
    local message="$1"
    local channel="${2:-test}"
    if [[ -z "$SLACK_WEBHOOK_URL" ]]; then return; fi
    curl -s -X POST "$SLACK_WEBHOOK_URL" \
        -H "Authorization: Bearer $SLACK_TOKEN" \
        -H "Content-Type: application/json" \
        -d "{\"message\": \"$message\", \"channel\": \"$channel\"}" \
    | jq -r '.message_id // empty'
}

# Send a threaded reply to an existing Slack message
# Usage: send_slack_thread "$THREAD_TS" "message" "channel"
send_slack_thread() {
    local thread_id="$1"
    local message="$2"
    local channel="${3:-test}"
    if [[ -z "$SLACK_WEBHOOK_URL" || -z "$thread_id" ]]; then return; fi
    curl -s -X POST "$SLACK_WEBHOOK_URL" \
        -H "Authorization: Bearer $SLACK_TOKEN" \
        -H "Content-Type: application/json" \
        -d "{\"message\": \"$message\", \"channel\": \"$channel\", \"parent_msg_id\": \"$thread_id\"}" \
    > /dev/null
}
