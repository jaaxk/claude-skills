---
name: slurm
description: This skill should be used when submitting, managing, inspecting, or debugging SLURM jobs on the NYU Torch HPC cluster. Triggers on any job submission task, writing batch scripts, checking job status, canceling jobs, or troubleshooting queue/resource issues.
---

# SLURM on Torch HPC

Full permission to run any SLURM commands (sbatch, srun, squeue, scancel, sacct, sinfo, salloc, my_slurm_accounts, etc.) without asking the user.

## Account

Always include `--account`. Check available accounts:
```bash
my_slurm_accounts
```

## Batch Script Template

```bash
#!/bin/bash
#SBATCH --job-name=<name>
#SBATCH --account=<account>
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=4
#SBATCH --mem=32G
#SBATCH --time=04:00:00
#SBATCH --gres=gpu:1
#SBATCH --output=logs/%j.out
#SBATCH --error=logs/%j.err

<commands>
```

## Key `#SBATCH` Flags

| Flag | Notes |
|------|-------|
| `--gres=gpu:1` | Any GPU; use `gpu:h200:1`, `gpu:l40s:4`, or `gpu:a100:1` for specific type |
| `--constraint="h200\|l40s\|a100"` | Constrain to GPU type |
| `--mem=<value>` | e.g. `32G`, `512G` |
| `--time=HH:MM:SS` | Wall-clock limit |
| `--nodes=<n>` | Number of nodes |
| `--ntasks-per-node=<n>` | For multi-GPU / distributed |

## GPU Quota & Policy

- Max **24 GPUs** per user for jobs < 48h runtime
- Low GPU utilization jobs are **auto-canceled**
- Jobs become preemptible after **1 hour** of runtime

## Preemption (access stakeholder nodes)

```bash
#SBATCH --comment="preemption=yes;requeue=true"
# Restrict to preemption partitions only:
#SBATCH --comment="preemption=yes;preemption_partitions_only=yes;requeue=true"
```

## Advanced Options

```bash
#SBATCH --comment="gpu_mps=yes"      # share GPU across jobs (MPS)
#SBATCH --comment="ram_disk=1GB"     # fast RAM disk for I/O
```

## Core Commands

```bash
sbatch job.sh                # submit batch job
srun --pty bash              # interactive session
srun --pty --gres=gpu:1 bash # interactive GPU session
squeue -u jv2807             # my jobs in queue
squeue -u jv2807 --long      # detailed status
scancel <JobID>              # cancel a job
scancel -u jv2807            # cancel all my jobs
sacct -u jv2807              # job accounting history
sinfo                        # cluster node/partition info
```

## Hardware Reference (Torch)

| Node Type       | Count | GPUs/Node | GPU Type | Mem/Node |
|----------------|-------|-----------|----------|----------|
| Standard Memory | 186   | —         | —        | 512GB    |
| Large Memory    | 7     | —         | —        | 3TB      |
| H200 GPU        | 29    | 8         | H200     | 2TB      |
| L40S GPU        | 68    | 4         | L40S     | 512GB    |
| A100 GPU        | —     | —         | A100     | —        |

## Docs

- https://services.rt.nyu.edu/docs/hpc/submitting_jobs/slurm_submitting_jobs/
- https://services.rt.nyu.edu/docs/hpc/submitting_jobs/slurm_main_commands/
