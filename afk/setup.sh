#!/bin/bash
# AFK Skill — One-time setup script
# Registers the PostToolUse hook in ~/.claude/settings.json
# Run once after cloning/copying the skills folder to a new machine.

set -euo pipefail

SETTINGS="$HOME/.claude/settings.json"
HOOK_CMD="bash $HOME/.claude/skills/afk/scripts/afk_hook.sh"

# Ensure settings.json exists
if [[ ! -f "$SETTINGS" ]]; then
    echo "{}" > "$SETTINGS"
    echo "Created $SETTINGS"
fi

# Check if hook is already registered
if jq -e '.hooks.PostToolUse[]?.hooks[]?.command' "$SETTINGS" 2>/dev/null | grep -q "afk_hook.sh"; then
    echo "AFK hook is already registered in $SETTINGS — nothing to do."
    exit 0
fi

# Append the PostToolUse hook entry
UPDATED=$(jq --arg cmd "$HOOK_CMD" '
  .hooks.PostToolUse = ((.hooks.PostToolUse // []) + [{
    "matcher": ".*",
    "hooks": [{"type": "command", "command": $cmd}]
  }])
' "$SETTINGS")

echo "$UPDATED" > "$SETTINGS"
echo "AFK hook registered in $SETTINGS"
echo "Restart Claude Code for the hook to take effect."
