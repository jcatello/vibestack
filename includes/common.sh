#!/bin/bash
# /opt/vibestack/includes/common.sh
# Vibestack Shared Functions & Configuration Loader

# --- CONFIG LOADER ---
CONFIG_FILE="/opt/vibestack/config/vibestack.conf"
if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
else
    echo "FATAL: Missing config file at $CONFIG_FILE" >&2
    exit 1
fi

export SLACK_WEBHOOK_URL
export SLACK_TOKEN

# --- SLACK FUNCTIONS ---

# Send an initial Slack message, returns the message_id for threading
# Usage: THREAD_TS=$(send_slack_initial "message" "channel")
send_slack_initial() {
    local message="$1"
    local channel="${2:-test}"
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
    if [ -n "$thread_id" ]; then
        curl -s -X POST "$SLACK_WEBHOOK_URL" \
            -H "Authorization: Bearer $SLACK_TOKEN" \
            -H "Content-Type: application/json" \
            -d "{\"message\": \"$message\", \"channel\": \"$channel\", \"parent_msg_id\": \"$thread_id\"}" \
        > /dev/null
    fi
}

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