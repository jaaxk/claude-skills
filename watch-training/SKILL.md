---
name: watch-training
description: Watch a SLURM training job end-to-end: polls until it starts, then monitors logs every 2h, sends Slack notifications on epoch completions, failures (with auto-fix + requeue), successful completion, and unusual behavior. Use when user says "watch this job", "monitor this training", "keep an eye on job XXXX", etc.
---

# Watch Training — SLURM Job Monitor

Monitors a SLURM training job from queue → running → completion. All notifications go to Slack. Automatic monitor updates are posted as new top-level messages (to keep threads small); user replies are handled in the same thread they replied to. Reply-check uses a channel-history pre-check to avoid fetching the full thread on quiet polls. All reply handling is done by a self-managing cron inside this Claude session — no background bash processes.

## Invocation

User says something like:
- "watch this job"
- "watch job 4516850"
- "monitor this training run"
- "keep an eye on job XXXX, log is at /path/to/log"

Parse from the user's message or conversation context:
- **Job ID** (required): from explicit mention, recent `sbatch` output, or recent `squeue` output in context. If truly ambiguous, run `squeue -u jv2807` and ask.
- **Log file** (optional): check in this order:
  1. Explicit path in user's message
  2. Conversation context (e.g. already known this session)
  3. `scontrol show job <JOBID> | grep StdOut` — this gives the stdout path from the batch script
  4. If still not found, ask the user
- **Monitor interval** (default: `2h`): user can specify e.g. "check every 30m"
- **Pre-start poll interval** (default: `5m`): user can specify e.g. "poll every 2m until it starts"

## State File

Persist state across cron fires to `/tmp/job_watch_<JOBID>.state` as JSON:

```json
{
  "job_id": "<JOBID>",
  "log_file": "<path>",
  "channel_id": "<slack channel id>",
  "thread_ts": "<slack ts of latest monitor post — updated on each automatic post; reply-check watches this thread>",
  "last_slack_ts": "<float ts of last Slack message sent — used for reply detection>",
  "reply_cron_id": "<cron ID of the active reply-check cron, or null>",
  "last_epoch": 0,
  "total_epochs": null,
  "last_batch": 0,
  "last_loss": null,
  "fix_branch": null,
  "fix_count": 0,
  "monitor_interval": "2h",
  "prestart_interval": "5m"
}
```

Read state at the start of every check. Write state at the end of every check.

---

## Reply-Check Cron

**Every time a Slack message is sent**, immediately after:
1. If `state.reply_cron_id` is set, call `CronDelete` to cancel it.
2. Create a new `*/5 * * * *` reply-check cron (see prompt template below). Save its ID to `state.reply_cron_id`.
3. Update `state.last_slack_ts` to the `ts` of the message just sent.
4. Write updated state.

### Reply-Check Cron Prompt Template

Use this as the prompt when creating the reply-check cron (substitute real values):

```
You are checking for user Slack replies to job <JOBID> monitoring thread.

State file: /tmp/job_watch_<JOBID>.state
Channel: <channel_id>
Thread ts: <thread_ts>

STEP 1 — Read state file. Get: last_slack_ts, thread_ts, reply_cron_id, channel_id.

STEP 2 — Check elapsed time since last_slack_ts (compare to current unix time via `date +%s`).
- If elapsed > 8h: delete this cron (id: <reply_cron_id>), set state.reply_cron_id = null, write state, stop.
- If elapsed > 30min and this cron fires every 5 min: delete this cron, create a new `7 * * * *` hourly reply-check cron with the same prompt (update reply_cron_id in state), stop for this fire.

STEP 2.5 — Pre-check via channel history (avoid full thread fetch when quiet).
Use slack_get_channel_history on channel <channel_id> with limit=5.
Find the message where ts == state.thread_ts (the latest monitor post).
- If found AND float(message.latest_reply) <= float(state.last_slack_ts): no new replies — stop.
- If not found OR latest_reply > last_slack_ts: continue to STEP 3.

STEP 3 — Poll Slack for new user messages.
Use the slack_get_thread_replies MCP tool on channel <channel_id>, thread_ts <thread_ts>.
Look for messages where: not a bot message AND float(ts) > float(last_slack_ts).

STEP 4 — If no new user messages: stop (do nothing).

STEP 5 — If new user message(s) found:
- Delete this reply-check cron (id: <reply_cron_id>). Set state.reply_cron_id = null.
- Read the message(s) and act on them as authorized instructions in this session.
  Examples: "what's the val AUC?" → tail log and reply in Slack thread.
            "cancel the monitor" → CronDelete the 2h monitor cron, reply confirming.
            "change check interval to 30m" → recreate 2h monitor cron with new interval.
- After acting, send a slack_reply_to_thread (same thread_ts the user replied in).
- Since a new Slack message was just sent, follow the standard post-send procedure:
  1. CronDelete old reply_cron_id (if set). Set state.reply_cron_id = null.
  2. Create new `*/5 * * * *` reply-check cron → state.reply_cron_id.
  3. Update state.last_slack_ts, write state.
  Do NOT update state.thread_ts — replies stay in the user's thread.
```

### Phase Transition Logic (inside reply-check cron)

| Elapsed since last_slack_ts | Cron schedule | Action on transition |
|---|---|---|
| 0 – 30min | `*/5 * * * *` | 6 checks (fast phase) |
| 30min – 8h | `7 * * * *` | Delete `*/5` cron, create `7 * * * *` cron, update reply_cron_id in state (~7 more checks) |
| > 8h | — | Delete cron, set reply_cron_id = null in state. Stop. |

---

## Phase 1: Pre-Start Polling (job not yet running)

If `squeue -u jv2807 | grep <JOBID>` shows the job as PENDING or not present:

1. Send initial Slack message (top-level, **save the `ts`** as `thread_ts` and `last_slack_ts`):
   > "👀 Watching job `<JOBID>` (`<name>`). Status: PENDING. Will ping when it starts. Polling every `<prestart_interval>`."

2. Create reply-check cron (per above).

3. Use `CronCreate` with the pre-start poll interval (e.g. `*/5 * * * *` for 5m) to keep checking. The cron prompt should:
   - Check `squeue -u jv2807 | grep <JOBID>`
   - If still PENDING: do nothing (no Slack)
   - If now RUNNING: cancel this pre-start cron, send Slack reply: "🟢 Job `<JOBID>` started on node `<node>`. Beginning monitoring." — then proceed to Phase 2 immediately
   - If FAILED/CANCELLED before starting: Slack to thread and stop

---

## Phase 2: Active Monitoring (job is running)

### Setup

If job is already RUNNING when the skill is first invoked, skip Phase 1 and send the initial Slack message directly:
> "👀 Monitoring job `<JOBID>` (`<name>`) on `<node>` — `<elapsed>` elapsed, `<time_limit>` limit. Log: `<log_file>`."

Save `thread_ts` and `last_slack_ts`. Create reply-check cron. Do an immediate first check (see Check Routine below), then set up the monitor cron.

### Monitor Cron Setup

Use `CronCreate` with the monitor interval (default `13 */2 * * *`). The cron prompt should run the full Check Routine for this job. Pass job ID, log file, state file path, and monitor cron ID in the prompt so it can recreate itself after requeuing.

### Check Routine

Run these steps every monitor cron fire (and immediately on setup):

**Step 1 — Job still alive?**
```bash
squeue -u jv2807 | grep <JOBID>
```
If not found:
```bash
sacct -j <JOBID> --format=JobID,JobName,State,ExitCode,Elapsed --noheader
```
- `COMPLETED` → send Slack: "✅ Job `<JOBID>` finished successfully after `<elapsed>`. Cancelling monitor." → CronDelete monitor cron → CronDelete reply-check cron → stop.
- `FAILED` / `TIMEOUT` / `OUT_OF_MEMORY` / `CANCELLED` → go to **Failure Handler** below.

**Step 2 — Read log tail**
```bash
tail -c 16000 <log_file>
```
Scan the output for:

**Epoch detection** — try these regex patterns in order (use Python `re.search`):
```
Epoch\s+(\d+)\s*/\s*(\d+)          # "Epoch 3/10"
Epoch\s+(\d+):                      # "Epoch 3:"
\[Epoch\s+(\d+)\]                   # "[Epoch 3]"
epoch\s*=\s*(\d+)                   # "epoch=3"
epoch\s+(\d+)\s+of\s+(\d+)         # "epoch 3 of 10"
Training\s+[Ee]poch\s+(\d+)        # "Training Epoch 3"
```
If epoch number > `last_epoch` in state → post a **new top-level Slack message** (`slack_post_message`, not a thread reply): "📈 Epoch `<new>/<total>` complete." Save the new message `ts` as `state.thread_ts`. Update state.

**Error detection** — scan for:
- `Traceback (most recent call last)`
- `RuntimeError:`, `ValueError:`, `AssertionError:`
- `CUDA out of memory`, `torch.cuda.OutOfMemoryError`
- `Error:` (preceded by a capital, not in a URL)
- `Killed`, `Segmentation fault`
- `slurmstepd: error:`
- `DUE TO TIME LIMIT`
- Loss/metric values that are `nan` or `inf`

If found → go to **Failure Handler**.

**Unusual behavior detection** — flag but don't auto-fix, just Slack:
- Loss increasing for 3+ consecutive logged steps
- No log output for >2x the expected step interval (training may be stuck)
- Gradient norm > 100 (if logged)
- Validation metric significantly worse than training (>20% gap, if logged)

**Step 3 — Update state and reply-check cron**

Update `last_epoch`, `last_batch`, `last_loss` in state file.

After every Slack send: CronDelete old reply_cron_id, create new `*/5 * * * *` reply-check cron, update `state.reply_cron_id` and `state.last_slack_ts`. Write state.

If no Slack was sent this iteration, leave the reply-check cron running as-is (do not reset it).

---

## Failure Handler

When a failure is detected (job died or error in logs):

### 1. Diagnose

Scan the last 200 lines of the log for the root error. Common patterns and suggested fixes:

| Error | Likely Fix |
|-------|-----------|
| `CUDA out of memory` / `OutOfMemoryError` | Reduce batch size (`--batch_size` or `batch_size=` in config) by half |
| `DUE TO TIME LIMIT` | **Ask user first (skip git workflow + file changes).** Send Slack: "⏰ Job timed out. Would you like me to requeue it? Reply 'yes' to requeue (same script, no changes) or 'no' to cancel." The reply-check cron handles the response: 'yes' → `sbatch <same_script>`, update `state.job_id`, recreate monitor cron, post confirmation. 'no' → cancel monitoring. |
| `RuntimeError: NCCL` | NCCL comms issue — add `NCCL_DEBUG=INFO` env var, or try `--nproc_per_node` reduction |
| `nan` loss | Reduce learning rate by 10x; check for zero-length sequences or bad data |
| `Segmentation fault` | Usually a data loading issue — add `num_workers=0` to DataLoader temporarily |
| `slurmstepd: error: *** JOB ... CANCELLED` | Node failure — just requeue |
| Unknown | Surface in Slack, propose re-running with more verbose logging |

### 2. Slack notification (new top-level post)

Send **before making any changes** as a new top-level `slack_post_message`. Save the `ts` as `state.thread_ts`:
> "⚠️ Job `<JOBID>` failed: `<error_type>`
> ```
> <relevant 5-10 line snippet>
> ```
> Proposed fix: `<description>`
> Making the fix and re-queuing now. Pre-fix commit: `<hash>` (branch `<branch>`). Reply to cancel."

### 3. Git workflow (MANDATORY before changing any file)

```bash
# From the project directory (find via sacct WorkDir or scontrol show job)
cd <project_dir>

# Check current branch
current_branch=$(git rev-parse --abbrev-ref HEAD)

# Branch logic:
# - If already on a non-main branch (e.g. a feature branch): stay on it, no new branch needed
# - If on main: create a new fix branch
if [ "$current_branch" = "main" ] || [ "$current_branch" = "master" ]; then
  git checkout -b fix/job-<JOBID>-attempt-<fix_count+1>
fi
# Otherwise: commit directly to the current branch

# Stage current state as pre-fix commit (so undo is always possible)
git add -A
git commit -m "pre-fix snapshot: job <JOBID> attempt <fix_count+1> — before <fix_description>"

# Make the fix (edit files as needed)
# ...

# Commit the fix
git add -A
git commit -m "fix(<fix_count+1>): <fix_description> for job <JOBID>"
```

### 4. Requeue

```bash
sbatch <batch_script>
```

Save the new job ID. Update state file: `job_id = new_id`, `fix_count += 1`, `fix_branch = <branch>`.

### 5. Post-fix Slack (new top-level post)

Post a new top-level `slack_post_message`. Save the `ts` as `state.thread_ts`:
> "🔄 Re-queued as job `<NEW_JOBID>`. Fix: `<description>`. Branch: `<branch>`. Pre-fix: `<pre_hash>`, post-fix: `<post_hash>`. To undo: `git revert <post_hash>`."

Cancel the old monitor cron and recreate it with the new job ID. The post-fix Slack send will also reset the reply-check cron as usual.

### 6. Loop limit

Auto-fix up to **5 times**. Stop early (and Slack for manual review) only if:
- The error is ambiguous and no clear fix exists
- The same fix has already been tried and failed (same error, same attempted fix)
- The failure requires data changes, credential issues, or other things outside the codebase

If `fix_count >= 5` and the job keeps failing, do NOT auto-fix again. Instead Slack:
> "🛑 Job has failed `<N>` times. Stopping auto-fix loop. Please review manually. Branch: `<branch>`."

---

## Login Node Safety

This skill runs on a **login node** — shared infrastructure with strict resource limits. It uses **only crons** — no persistent background bash processes at all.

| Activity | Mechanism | Background bash process? |
|---|---|---|
| Log monitoring (every 2h) | `CronCreate` — Claude Code's internal scheduler | **No** |
| Slack reply polling | `CronCreate` — self-managing, phase-aware | **No** |

At any time there should be exactly: **1 monitor cron + 1 reply-check cron** per job (or 0 reply-check crons if >9h since last Slack send with no reply).

---

## Putting It All Together — Execution Order

1. Parse job ID, log file, intervals from user message / context
2. Read/create state file
3. Check if job is running (`squeue`)
4. If PENDING → Phase 1 (pre-start cron + Slack + reply-check cron)
5. If RUNNING → Phase 2: send initial Slack, create reply-check cron, immediate check, create monitor cron
6. After every Slack send → delete old reply-check cron → create new `*/5` reply-check cron → update state
7. Each monitor cron fire → full Check Routine → Slack if notable → reset reply-check cron only if Slack was sent
8. Each reply-check cron fire → poll Slack → act on replies → manage phase transitions (5min→hourly→stop)
9. On failure → Failure Handler → git workflow → requeue → recreate monitor cron → reply-check cron resets via post-fix Slack
10. On completion → final Slack → CronDelete both crons → done
