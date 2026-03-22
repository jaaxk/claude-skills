#!/bin/bash

# Start Poll Script
# Sets up cron job to poll Slack thread every 5 minutes with 8-hour expiry
# Usage: ./start_poll.sh

set -e

SKILL_DIR="$HOME/.claude/skills/slack"
POLL_SCRIPT="$SKILL_DIR/scripts/slack_poll.sh"

# Function to sanitize TMUX_PANE for use in directory names
sanitize_pane_id() {
    echo "$1" | sed 's/[%:]/_/g'
}

# Get sanitized pane ID
if [[ -z "$TMUX_PANE" ]]; then
    echo "Error: TMUX_PANE not set. Must be run from within a tmux session." >&2
    exit 1
fi

TMUX_PANE_ID=$(sanitize_pane_id "$TMUX_PANE")
TEMP_DIR="$SKILL_DIR/temp/$TMUX_PANE_ID"

# Verify that slack_thread.txt exists
THREAD_FILE="$TEMP_DIR/slack_thread.txt"
if [[ ! -f "$THREAD_FILE" ]]; then
    echo "Error: $THREAD_FILE does not exist. Cannot start polling." >&2
    exit 1
fi

# Create unique cron marker
CRON_MARKER="slack_poll_${TMUX_PANE_ID}"

# Calculate expiry time (12 hours from now)
EXPIRY_TS=$(( $(date +%s) + 43200 ))

# Capture current environment variables for the wrapper script
CURRENT_TMUX_PANE="$TMUX_PANE"
CURRENT_SLACK_BOT_TOKEN="$SLACK_BOT_TOKEN"
CURRENT_SLACK_CHANNEL="$SLACK_CHANNEL"

# Get tmux socket path - extract from $TMUX or find the default socket
if [[ -n "$TMUX" ]]; then
    # TMUX var format: /path/to/socket,pid,pane
    TMUX_SOCKET=$(echo "$TMUX" | cut -d',' -f1)
else
    # Find tmux socket for current user
    TMUX_SOCKET=$(find /tmp/tmux-* -name default 2>/dev/null | head -1)
fi

# Create wrapper script that checks expiry and calls poll script
WRAPPER_SCRIPT="$TEMP_DIR/run_poll_wrapper.sh"

cat > "$WRAPPER_SCRIPT" <<EOF
#!/bin/bash

# Cron wrapper for slack_poll.sh with 12-hour expiry
# Created: $(date)
# Expires: $(date -r $EXPIRY_TS 2>/dev/null || date -d @$EXPIRY_TS 2>/dev/null || echo "unknown")

# Export environment variables needed by poll script
export TMUX_PANE="$CURRENT_TMUX_PANE"
export SLACK_BOT_TOKEN="$CURRENT_SLACK_BOT_TOKEN"
export SLACK_CHANNEL="$CURRENT_SLACK_CHANNEL"
export TMUX_SOCKET="$TMUX_SOCKET"

# Check if expired (12 hours) — just exit, cron entry stays but is harmless
if [ \$(date +%s) -gt $EXPIRY_TS ]; then
    exit 0
fi

# Run the poll script with TEMP_DIR as argument (avoids env var dependency)
"$POLL_SCRIPT" "$TEMP_DIR"
EOF

chmod +x "$WRAPPER_SCRIPT"

# Remove any existing cron job with this marker, then add new one
( crontab -l 2>/dev/null | grep -v "$CRON_MARKER" || true ; echo "*/1 * * * * $WRAPPER_SCRIPT # $CRON_MARKER" ) | crontab -

# Save the cron marker to poll_pid.txt
echo "$CRON_MARKER" > "$TEMP_DIR/poll_pid.txt"

echo "Polling scheduled successfully!"
echo "Marker: $CRON_MARKER"
echo "Frequency: every 5 minutes"
echo "Expires: $(date -r $EXPIRY_TS 2>/dev/null || date -d @$EXPIRY_TS 2>/dev/null || echo 'in 8 hours')"
echo "To view: crontab -l | grep $CRON_MARKER"
echo "To cancel: crontab -l | grep -v $CRON_MARKER | crontab -"
