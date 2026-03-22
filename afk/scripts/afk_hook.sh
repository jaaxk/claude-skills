#!/bin/bash

# AFK Mode - PostToolUse Hook
# Fires after every tool call. If AFK mode is enabled, sends a summary to the Slack AFK thread.

SLACK_SKILL_DIR="$HOME/.claude/skills/slack"
SLACK_PING="$SLACK_SKILL_DIR/scripts/slack_ping.sh"

# Sanitize TMUX_PANE for directory names
sanitize_pane_id() {
    echo "$1" | sed 's/[%:]/_/g'
}

# Warn and exit if not in tmux
if [[ -z "$TMUX_PANE" ]]; then
    echo "[AFK hook] Warning: TMUX_PANE not set — AFK mode requires a tmux session." >&2
    exit 0
fi

PANE_ID=$(sanitize_pane_id "$TMUX_PANE")
TEMP_DIR="$SLACK_SKILL_DIR/temp/$PANE_ID"
AFK_STATE_FILE="$TEMP_DIR/afk_enabled"

# Exit silently if AFK is not enabled
if [[ ! -f "$AFK_STATE_FILE" ]]; then
    exit 0
fi

# Read tool event from stdin
INPUT=$(cat)
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // "unknown"')
TOOL_INPUT=$(echo "$INPUT" | jq -r '.tool_input // {}')

# Build a human-readable message based on tool type
case "$TOOL_NAME" in
    Bash)
        CMD=$(echo "$TOOL_INPUT" | jq -r '.command // ""')
        if [[ ${#CMD} -gt 200 ]]; then CMD="${CMD:0:200}..."; fi
        MESSAGE="🖥️ Bash: \`$CMD\`"
        ;;
    Edit)
        FILE=$(echo "$TOOL_INPUT" | jq -r '.file_path // ""')
        OLD=$(echo "$TOOL_INPUT" | jq -r '.old_string // ""' | head -c 60)
        MESSAGE="✏️ Edit: \`$FILE\` — \`$OLD\`..."
        ;;
    Write)
        FILE=$(echo "$TOOL_INPUT" | jq -r '.file_path // ""')
        MESSAGE="📝 Write: \`$FILE\`"
        ;;
    NotebookEdit)
        FILE=$(echo "$TOOL_INPUT" | jq -r '.notebook_path // ""')
        MESSAGE="📓 NotebookEdit: \`$FILE\`"
        ;;
    Read)
        FILE=$(echo "$TOOL_INPUT" | jq -r '.file_path // ""')
        MESSAGE="📖 Read: \`$FILE\`"
        ;;
    Grep)
        PATTERN=$(echo "$TOOL_INPUT" | jq -r '.pattern // ""')
        GPATH=$(echo "$TOOL_INPUT" | jq -r '.path // ""')
        MESSAGE="🔍 Grep: \`$PATTERN\`${GPATH:+ in \`$GPATH\`}"
        ;;
    Glob)
        PATTERN=$(echo "$TOOL_INPUT" | jq -r '.pattern // ""')
        MESSAGE="🗂️ Glob: \`$PATTERN\`"
        ;;
    WebFetch)
        URL=$(echo "$TOOL_INPUT" | jq -r '.url // ""')
        MESSAGE="🌐 WebFetch: $URL"
        ;;
    WebSearch)
        QUERY=$(echo "$TOOL_INPUT" | jq -r '.query // ""')
        MESSAGE="🔎 WebSearch: \"$QUERY\""
        ;;
    *)
        # Skip tools not in the tracked list
        exit 0
        ;;
esac

# Send to Slack AFK thread in background (don't block Claude)
"$SLACK_PING" "$MESSAGE" --afk > /dev/null 2>&1 &

exit 0
