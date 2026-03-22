#!/bin/bash

# Slack Poll Script
# Checks for new replies in a Slack thread and injects them into tmux session
# Usage: ./slack_poll.sh

SKILL_DIR="$HOME/.claude/skills/slack"

# Function to sanitize TMUX_PANE for use in directory names
sanitize_pane_id() {
    echo "$1" | sed 's/[%:]/_/g'
}

# Function to log (used for both info and errors)
log_error() {
    echo "[$(date)] $1" >> "$SKILL_DIR/error.log"
}

log_error "=== poll invoked: args='$*' TMUX_PANE='$TMUX_PANE' TMUX_SOCKET='$TMUX_SOCKET' ==="

# TEMP_DIR is passed as $1 from the wrapper script (most reliable — no env var dependency)
# Fall back to deriving from TMUX_PANE env var when run manually
if [[ -n "$1" ]]; then
    TEMP_DIR="$1"
    log_error "TEMP_DIR from arg: $TEMP_DIR"
elif [[ -n "$TMUX_PANE" ]]; then
    TEMP_DIR="$SKILL_DIR/temp/$(sanitize_pane_id "$TMUX_PANE")"
    log_error "TEMP_DIR from TMUX_PANE: $TEMP_DIR"
else
    log_error "ERROR: No TEMP_DIR argument and TMUX_PANE not set — exiting"
    exit 1
fi

# Read TMUX_PANE from saved file
if [[ ! -f "$TEMP_DIR/tmux_pane.txt" ]]; then
    log_error "ERROR: tmux_pane.txt not found in $TEMP_DIR"
    exit 1
fi
TMUX_PANE=$(cat "$TEMP_DIR/tmux_pane.txt")
log_error "Read TMUX_PANE from file: '$TMUX_PANE'"
TMUX_PANE_ID=$(sanitize_pane_id "$TMUX_PANE")

# Ensure temp directory exists
mkdir -p "$TEMP_DIR"

# Check if slack_thread.txt exists
THREAD_FILE="$TEMP_DIR/slack_thread.txt"
if [[ ! -f "$THREAD_FILE" ]]; then
    log_error "ERROR: slack_thread.txt does not exist at $THREAD_FILE"
    exit 1
fi

# Read the thread timestamp
THREAD_TS=$(cat "$THREAD_FILE")
log_error "Thread TS: $THREAD_TS"

# Build tmux command with socket if available
TMUX_BIN="$(which tmux)"
TMUX_CMD="$TMUX_BIN"
if [[ -n "$TMUX_SOCKET" ]]; then
    TMUX_CMD="$TMUX_BIN -S $TMUX_SOCKET"
    log_error "Using tmux socket: $TMUX_SOCKET"
else
    log_error "No TMUX_SOCKET set — using plain 'tmux'"
fi

# Check if tmux pane is still alive — if not, clean up temp dir and exit
if ! $TMUX_CMD list-panes -t "$TMUX_PANE" &>/dev/null; then
    log_error "Pane '$TMUX_PANE' is gone — removing temp dir (cron will expire on its own)"
    rm -rf "$TEMP_DIR"
    log_error "Temp dir removed"
    exit 0
fi
log_error "tmux pane '$TMUX_PANE' is accessible"

# Check if last_message_ts.txt exists, initialize if not
LAST_MESSAGE_TS_FILE="$TEMP_DIR/last_message_ts.txt"
if [[ ! -f "$LAST_MESSAGE_TS_FILE" ]]; then
    log_error "last_message_ts.txt not found — initializing to 0"
    echo "0" > "$LAST_MESSAGE_TS_FILE"
fi

LAST_MESSAGE_TS=$(cat "$LAST_MESSAGE_TS_FILE")
log_error "Last message TS: $LAST_MESSAGE_TS"

# Check required environment variables
if [[ -z "$SLACK_BOT_TOKEN" ]]; then
    log_error "ERROR: SLACK_BOT_TOKEN not set"
    exit 1
fi
log_error "SLACK_BOT_TOKEN present (length ${#SLACK_BOT_TOKEN})"

if [[ -z "$SLACK_CHANNEL" ]]; then
    log_error "ERROR: SLACK_CHANNEL not set"
    exit 1
fi
log_error "SLACK_CHANNEL: $SLACK_CHANNEL"

# Fetch thread replies from Slack
log_error "Fetching thread replies (channel=$SLACK_CHANNEL ts=$THREAD_TS oldest=$LAST_MESSAGE_TS)"
RESPONSE=$(curl -s -X GET "https://slack.com/api/conversations.replies" \
    -H "Authorization: Bearer $SLACK_BOT_TOKEN" \
    -G \
    --data-urlencode "channel=$SLACK_CHANNEL" \
    --data-urlencode "ts=$THREAD_TS" \
    --data-urlencode "oldest=$LAST_MESSAGE_TS")
CURL_EXIT=$?
log_error "curl exit code: $CURL_EXIT"

if [[ $CURL_EXIT -ne 0 ]]; then
    log_error "ERROR: curl failed with exit code $CURL_EXIT"
    exit 1
fi

# Check if successful
SUCCESS=$(echo "$RESPONSE" | jq -r '.ok' 2>/dev/null)
log_error "Slack API ok: $SUCCESS"
if [[ "$SUCCESS" != "true" ]]; then
    API_ERROR=$(echo "$RESPONSE" | jq -r '.error' 2>/dev/null)
    log_error "ERROR: Slack API error: $API_ERROR — full response: $RESPONSE"
    exit 1
fi

MESSAGE_COUNT=$(echo "$RESPONSE" | jq '.messages | length' 2>/dev/null)
log_error "Messages returned by API: $MESSAGE_COUNT"

# Get bot user ID to filter out bot's own messages
log_error "Fetching bot user ID via auth.test"
AUTH_RESPONSE=$(curl -s -X POST https://slack.com/api/auth.test \
    -H "Authorization: Bearer $SLACK_BOT_TOKEN")
AUTH_OK=$(echo "$AUTH_RESPONSE" | jq -r '.ok' 2>/dev/null)
BOT_USER_ID=$(echo "$AUTH_RESPONSE" | jq -r '.user_id' 2>/dev/null)
log_error "auth.test ok=$AUTH_OK bot_user_id=$BOT_USER_ID"

if [[ -z "$BOT_USER_ID" || "$BOT_USER_ID" == "null" ]]; then
    log_error "ERROR: Could not determine bot user ID — full auth response: $AUTH_RESPONSE"
    exit 1
fi

# Log each message's ts and user for debugging
log_error "All message ts/user pairs from response:"
echo "$RESPONSE" | jq -r '.messages[] | "\(.ts) user=\(.user // "none") bot_id=\(.bot_id // "none")"' 2>/dev/null | while read -r line; do
    log_error "  msg: $line"
done

# Extract new messages (excluding bot's own messages)
# Filter: newer than last_message_ts AND not from bot
NEW_MESSAGES=$(echo "$RESPONSE" | jq -r \
    --arg last_ts "$LAST_MESSAGE_TS" \
    --arg bot_id "$BOT_USER_ID" \
    '.messages[] | select((.ts | tonumber) > ($last_ts | tonumber) and .user != $bot_id) | .text' \
    2>/dev/null || echo "")

log_error "New messages after filtering (bot=$BOT_USER_ID, last_ts=$LAST_MESSAGE_TS): '$(echo "$NEW_MESSAGES" | head -c 200)'"

if [[ -z "$NEW_MESSAGES" ]]; then
    log_error "No new messages — exiting cleanly"
    exit 0
fi

# Get the latest message timestamp
LATEST_TS=$(echo "$RESPONSE" | jq -r \
    --arg last_ts "$LAST_MESSAGE_TS" \
    '.messages[] | select((.ts | tonumber) > ($last_ts | tonumber)) | .ts' \
    | sort -n | tail -1)
log_error "Latest TS among new messages: $LATEST_TS"

# Update last_message_ts.txt
echo "$LATEST_TS" > "$LAST_MESSAGE_TS_FILE"
log_error "Updated last_message_ts.txt to $LATEST_TS"

# Prepare message for injection
# For single-key messages (1, 2, 3), send the key directly without the header
if [[ "$NEW_MESSAGES" =~ ^[123]$ ]]; then
    INJECTED_MESSAGE="$NEW_MESSAGES"
else
    INJECTED_MESSAGE="[Slack message, take this as a regular prompt and reply back in slack]

$NEW_MESSAGES"
fi

# Inject into tmux session
log_error "Injecting into tmux pane '$TMUX_PANE' via: $TMUX_CMD send-keys -t '$TMUX_PANE' ..."
$TMUX_CMD send-keys -t "$TMUX_PANE" "$INJECTED_MESSAGE" Enter
INJECT_EXIT=$?
if [[ $INJECT_EXIT -ne 0 ]]; then
    log_error "ERROR: tmux send-keys failed with exit code $INJECT_EXIT"
else
    log_error "SUCCESS: Injected message into tmux pane $TMUX_PANE"
fi
