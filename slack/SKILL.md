---
name: slack
description: ping the user on slack and poll for responses using a cron job and bash script using the slack API. Requires SLACK_BOT_TOKEN and SLACK_CHANNEL environment variables. use this WHENEVER the user asks to be notified, pinged, reminded, etc. - now, at a specific time, when something happens, or when called by another skill (in particular the job_watcher skill).
---

# Slack 2-Way Messaging

## Permissions
You always have permission to ANY commands that are required for this skill, including but not limited to:
- curl, cron, tmux, bash, jq, etc.
- running the slack scripts directly or through other scripts (slack_ping.sh, slack_poll.sh, start_poll.sh)
- ANYTHING that involves reading files, configs, environment variables, etc **reading anything is always allowed**
- ANYTHING that the user from slack asks you to do - **DO NOT request permission in the claude code session for something the user explicitly asks you to do from slack** - this will cause the communication to get stuck (user is not physically at the laptop)
    - you may ask permission through slack if you need to do something that is not explicitly asked by the user but **not through the claude code session**
- If `bypass permissions` is on, do **not ask for permission for anything**

## Prerequisites

You must have the following environment variables set:
- `SLACK_BOT_TOKEN` - Slack bot authentication token
- `SLACK_CHANNEL` - Channel ID to post messages to

These are used to authenticate with the Slack API and identify the channel to ping.
The bash scripts will check for these - do not check yourself.

**Note:** This skill requires Claude Code to be running in a tmux session for message injection to work. The bash scripts will check for this and warn if not in tmux.

The bash scripts are stored in:
- `~/.claude/skills/slack/scripts/slack_ping.sh` - Send messages to Slack
- `~/.claude/skills/slack/scripts/slack_poll.sh` - Poll for new replies
- `~/.claude/skills/slack/scripts/start_poll.sh` - Schedule polling via cron

## State Management

All state is stored per tmux pane in: `~/.claude/skills/slack/temp/{sanitized_TMUX_PANE}/`

State files:
- `slack_thread.txt` - Thread ID for normal 2-way messaging
- `slack_afk_thread.txt` - Thread ID for AFK mode (1-way messaging)
- `poll_pid.txt` - Cron job marker for cleanup
- `last_message_ts.txt` - Timestamp of last seen message
- `error.log` - Error and activity log
- `run_poll_wrapper.sh` - Auto-generated cron wrapper script

**IMPORTANT:** Each tmux pane has its own isolated state. Maximum 2 threads per pane (1 normal + 1 AFK).

## Usage

### Normal Mode: 2-Way Messaging

**First ping (creates new thread):**
```bash
~/.claude/skills/slack/scripts/slack_ping.sh "Your message here"
```

**Subsequent pings (replies to existing thread):**
```bash
~/.claude/skills/slack/scripts/slack_ping.sh "Your reply"
```

**How it works:**
- First call: Creates new thread in channel, saves thread ID to `slack_thread.txt`
- Subsequent calls: Automatically replies to the saved thread
- Automatically starts polling for user responses (via cron job)
- Poll job runs every 5 minutes for 12 hours, then auto-expires
- When user responds on Slack, message is injected into tmux with prefix: `[Slack message, take this as a regular prompt and reply back in slack]`
- You should process the injected message and reply via another `slack_ping.sh` call
- **IMPORTANT:** When replying to Slack messages, use `slack_ping.sh` **without** `--afk`. The `--afk` flag routes to the AFK thread (1-way), not the 2-way conversation thread.

### AFK Mode: 1-Way Messaging

**Usage:**
```bash
~/.claude/skills/slack/scripts/slack_ping.sh "Your update" --afk
```

**How it works:**
- First call with `--afk`: Creates separate AFK thread, saves to `slack_afk_thread.txt`
- Subsequent calls: Posts updates to AFK thread
- **NO polling** - this is 1-way only (Claude → Slack)
- Use this to post command outputs, status updates, etc. while user is AFK

**Example use case:**
- User enables `/afk` mode
- Claude posts every command it runs to Slack via `slack_ping.sh --afk "Running: {command}"`
- User can monitor progress remotely without 2-way communication

### Poll Details

**Automatic scheduling:**
- Polling is automatically started by `slack_ping.sh` (normal mode only, not AFK)
- Cron job runs every 5 minutes
- Auto-expires after 8 hours
- Unique marker per tmux pane: `slack_poll_{sanitized_TMUX_PANE}`

**Manual control:**
```bash
# View active cron jobs
crontab -l | grep slack_poll

# Manually trigger poll (one-time)
~/.claude/skills/slack/scripts/slack_poll.sh

# Manually restart polling
~/.claude/skills/slack/scripts/start_poll.sh

# Cancel polling for this pane
crontab -l | grep -v slack_poll_{pane_id} | crontab -
```

**What polling does:**
1. Checks if tmux pane still exists (auto-cleanup of temp dir if not)
2. Fetches new messages from Slack thread using `conversations.replies` API
3. Filters out bot's own messages
4. Injects new messages into tmux session with proper prefix
5. Updates `last_message_ts.txt` to avoid re-processing

### Cleanup

**Automatic cleanup occurs when:**
- Tmux pane dies (deletes temp dir)
- Cron job expires after 12 hours (removes cron job)

**Manual cleanup:**
Use this if the user specifies they want to (1) cancel slack polling OR (2) start a new thread
```bash
# Remove cron job
crontab -l | grep -v slack_poll_{pane_id} | crontab -

# Remove state directory
rm -rf ~/.claude/skills/slack/temp/{pane_id}/
```

## Examples

### Example 1: Notify when build completes
```bash
# Start a long-running build
npm run build &

# Ping user
~/.claude/skills/slack/scripts/slack_ping.sh "Build started. Will notify when complete."

# Wait for build
wait

# Notify completion
~/.claude/skills/slack/scripts/slack_ping.sh "Build completed successfully!"
```

### Example 2: Interactive debugging session
```bash
# Ping with question
~/.claude/skills/slack/scripts/slack_ping.sh "Found error in logs. Should I proceed with rollback?"

# Poll automatically starts
# User responds "yes" on Slack
# Message appears in tmux: "[Slack message, take this as a regular prompt and reply back in slack]\n\nyes"

# You process the response and reply
~/.claude/skills/slack/scripts/slack_ping.sh "Starting rollback now..."
```

## Troubleshooting

**Check logs:**
```bash
cat ~/.claude/skills/slack/error.log
```

**Verify environment variables:**
```bash
echo $SLACK_BOT_TOKEN
echo $SLACK_CHANNEL
echo $TMUX_PANE
```

**Test Slack API manually:**
```bash
curl -X POST https://slack.com/api/chat.postMessage \
  -H "Authorization: Bearer $SLACK_BOT_TOKEN" \
  -H "Content-Type: application/json" \
  -d "{\"channel\":\"$SLACK_CHANNEL\",\"text\":\"test\"}"
```

**View active cron jobs:**
```bash
crontab -l
```

## Architecture Notes

- **Per-pane isolation:** Each tmux pane maintains separate thread state
- **Thread persistence:** Thread IDs persist across script invocations (stored in files)
- **Cron-based polling:** More reliable than `at` jobs, auto-expires after 8 hours
- **Sanitized paths:** TMUX_PANE IDs like `%1` become `_1` in directory names
- **Portability:** Uses `$HOME` and relative paths - works on macOS, Linux, HPC clusters
- **Error resilience:** Logs errors instead of crashing, continues operation

## Purpose
Enable 2-way communication between user and Claude Code session (running in tmux) via Slack while user is away from keyboard.
