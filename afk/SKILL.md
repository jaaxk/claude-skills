---
name: afk
description: Toggle AFK (Away From Keyboard) mode. When enabled, a PostToolUse hook sends a summary of every tool (that involves writing to files or changing settings) Claude runs to a dedicated Slack thread so the user can monitor remotely. Toggle on with /afk, toggle off with /afk again.
---

# AFK Mode

## Overview

AFK mode broadcasts a summary of every significant mutable tool use (file writes, bash commands (other than slack_ping.sh), settings changes) to a dedicated Slack AFK thread. The hook (`afk_hook.sh`) fires automatically — you do not need to call anything manually per-tool.

## How to Toggle

### Determine current state first
```bash
# Compute pane-specific state file path
PANE_ID=$(echo "$TMUX_PANE" | sed 's/[%:]/_/g')
AFK_STATE_FILE="$HOME/.claude/skills/slack/temp/$PANE_ID/afk_enabled"
```
- If `$AFK_STATE_FILE` **exists** → AFK is currently ON
- If `$AFK_STATE_FILE` **does not exist** → AFK is currently OFF

---

### Enabling AFK Mode

1. Create the temp dir and state file:
   ```bash
   mkdir -p "$(dirname "$AFK_STATE_FILE")"
   touch "$AFK_STATE_FILE"
   ```

2. Initialize the Slack AFK thread (no message → uses default init text):
   ```bash
   ~/.claude/skills/slack/scripts/slack_ping.sh --afk
   ```

3. Tell the user: **"AFK mode enabled. All tool activity will be posted to Slack."**

---

### Disabling AFK Mode

1. Remove the state file:
   ```bash
   rm "$AFK_STATE_FILE"
   ```

2. Send a final message to the Slack AFK thread:
   ```bash
   ~/.claude/skills/slack/scripts/slack_ping.sh "AFK mode disabled." --afk
   ```

3. Tell the user: **"AFK mode disabled."**

---

## State

| File | Location |
|------|----------|
| State flag | `~/.claude/skills/slack/temp/{pane_id}/afk_enabled` |
| AFK thread ID | `~/.claude/skills/slack/temp/{pane_id}/slack_afk_thread.txt` |

State is scoped per tmux pane (same isolation as the slack skill). It is automatically cleaned up when the tmux pane closes.

## Hook

The `PostToolUse` hook at `~/.claude/skills/afk/scripts/afk_hook.sh` runs after every tool call.

**Tracked tools (sends to Slack):** `Bash`, `Edit`, `Write`, `NotebookEdit`, `Read`, `Grep`, `Glob`, `WebFetch`, `WebSearch`

**Not tracked:** `Agent`, task management tools, plan tools (don't directly touch disk/web).

The hook runs the Slack send in the background so it does not block Claude.

## Requirements

- Must be in a tmux session (`$TMUX_PANE` must be set)
- `SLACK_BOT_TOKEN` and `SLACK_CHANNEL` environment variables must be set
- Slack skill scripts must be at `~/.claude/skills/slack/scripts/`
