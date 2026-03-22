#!/bin/bash

# Slack Ping Script
# Sends a message to Slack channel or replies to a thread
# Usage: ./slack_ping.sh "message" [--afk]

set -e

SKILL_DIR="$HOME/.claude/skills/slack"

# Parse arguments
MESSAGE=""
AFK_MODE=false

for arg in "$@"; do
    if [[ "$arg" == "--afk" ]]; then
        AFK_MODE=true
    else
        MESSAGE="$arg"
    fi
done

# Function to sanitize TMUX_PANE for use in directory names
sanitize_pane_id() {
    echo "$1" | sed 's/[%:]/_/g'
}

# Check if we're in a tmux session
if [[ -z "$TMUX" ]]; then
    echo "Warning: not in tmux session" >&2
fi

# Set TMUX_PANE_ID if in tmux
TMUX_PANE_ID=""
if [[ -n "$TMUX_PANE" ]]; then
    TMUX_PANE_ID=$(sanitize_pane_id "$TMUX_PANE")
fi

# Create temp directory for this pane
TEMP_DIR="$SKILL_DIR/temp/$TMUX_PANE_ID"
mkdir -p "$TEMP_DIR"

# Save TMUX_PANE to file so cron jobs can read it without environment
echo "$TMUX_PANE" > "$TEMP_DIR/tmux_pane.txt"

# Check required environment variables
if [[ -z "$SLACK_BOT_TOKEN" ]]; then
    echo "Error: SLACK_BOT_TOKEN environment variable is not set" >&2
    exit 1
fi

if [[ -z "$SLACK_CHANNEL" ]]; then
    echo "Error: SLACK_CHANNEL environment variable is not set" >&2
    exit 1
fi

# Determine which thread file to use based on mode
if [[ "$AFK_MODE" == true ]]; then
    THREAD_FILE="$TEMP_DIR/slack_afk_thread.txt"
else
    THREAD_FILE="$TEMP_DIR/slack_thread.txt"
fi

# Check if thread exists
THREAD_TS=""
if [[ -f "$THREAD_FILE" ]]; then
    THREAD_TS=$(cat "$THREAD_FILE")
fi

# Handle AFK mode initialization
if [[ "$AFK_MODE" == true ]] && [[ -z "$THREAD_TS" ]]; then
    MESSAGE="initializing AFK thread..."
fi

# Build the JSON payload
if [[ -n "$THREAD_TS" ]]; then
    # Reply in thread
    JSON_PAYLOAD=$(jq -n \
        --arg channel "$SLACK_CHANNEL" \
        --arg text "$MESSAGE" \
        --arg thread_ts "$THREAD_TS" \
        '{channel: $channel, text: $text, thread_ts: $thread_ts}')
else
    # New message to channel
    JSON_PAYLOAD=$(jq -n \
        --arg channel "$SLACK_CHANNEL" \
        --arg text "$MESSAGE" \
        '{channel: $channel, text: $text}')
fi

# Send the message
RESPONSE=$(curl -s -X POST https://slack.com/api/chat.postMessage \
    -H "Authorization: Bearer $SLACK_BOT_TOKEN" \
    -H "Content-Type: application/json" \
    -d "$JSON_PAYLOAD")

# Check if successful
SUCCESS=$(echo "$RESPONSE" | jq -r '.ok')
if [[ "$SUCCESS" != "true" ]]; then
    echo "Error sending message:" >&2
    echo "$RESPONSE" | jq . >&2
    exit 1
fi

# Extract the response timestamp
RESPONSE_TS=$(echo "$RESPONSE" | jq -r '.ts')

# If this was a new thread (not a reply), save the thread_ts
if [[ -z "$THREAD_TS" ]]; then
    echo "$RESPONSE_TS" > "$THREAD_FILE"
    THREAD_TS="$RESPONSE_TS"
    echo "Created new thread: $THREAD_TS"
fi

echo "Message sent successfully to thread: $THREAD_TS"

# Start polling if NOT in AFK mode
if [[ "$AFK_MODE" == false ]]; then
    # Check if cron job is already running
    POLL_PID_FILE="$TEMP_DIR/poll_pid.txt"
    CRON_MARKER=""

    if [[ -f "$POLL_PID_FILE" ]]; then
        CRON_MARKER=$(cat "$POLL_PID_FILE")
        # Check if cron job with this marker exists
        if crontab -l 2>/dev/null | grep -q "$CRON_MARKER"; then
            echo "Refreshing poll expiry for marker: $CRON_MARKER"
            "$SKILL_DIR/scripts/start_poll.sh"
        else
            # Marker exists but cron job doesn't - restart it
            echo "Poll job not found, starting new one..."
            "$SKILL_DIR/scripts/start_poll.sh"
        fi
    else
        # No marker file - start poll
        echo "Starting poll process..."
        "$SKILL_DIR/scripts/start_poll.sh"
    fi
fi
