---
name: pull-request
description: Use this skill when opening or preparing a pull request for the dms_contrastive pipeline. Enforces pre-PR testing and description standards.
---

# Pull Request Workflow

## Pre-PR requirement: pipeline test

Before opening a pull request, the pipeline smoke test **must pass**, unless the user explicitly says to skip it.

Run `/test-pipeline` and confirm:
- SLURM job completes with exit code `0:0`
- Best val AUC ≥ 0.60

If the test fails, fix the issue and rerun before proceeding with the PR.

## PR description standards

Descriptions must be written in **clear, non-technical terms** where possible, but with **specific references to the code changed** — including file names, line numbers, or short snippets. Each fix or feature should be explained in terms of:
- **What** was changed (with code reference)
- **Why** it was needed (root cause or motivation)
- **How** it was validated (e.g. passed smoke test, job ID, val AUC)

### Example description format

```
## Summary

- Fixed `pipeline.py:2032` — `load_state_dict` was called on all DDP ranks but
  `best_model_state` was only assigned on rank 0, causing rank 1 to crash with
  `TypeError: NoneType`. Added `dist.broadcast_object_list` to sync state from
  rank 0 before restoring.

- Fixed `pipeline.py:2118` — OHE H5 files were opened read-only on all ranks
  during training to prevent concurrent writes. Rank 1's lock blocked rank 0
  from reopening as writable for the post-training baseline eval. Fixed by
  calling `close_h5()` on all ranks + `dist.barrier()` before rank 0 reopens.

## Test

Passed pipeline smoke test (job 4419557, val AUC 0.6252).
```

## Opening the PR

```bash
git push -u origin <branch>
gh pr create --title "<short title>" --body "..."
```

Keep the title under 70 characters. Use the body for details.
