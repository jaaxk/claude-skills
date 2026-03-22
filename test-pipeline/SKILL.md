---
name: test-pipeline
description: Run the DDP pipeline smoke test to verify that training, evaluation, and OHE baseline complete successfully on 2 GPUs. Use this after making changes to pipeline.py or related scripts before merging to main.
---

# Pipeline DDP Smoke Test

Submit the smoke test job and monitor it to completion.

## How to run

```bash
cd /home/jv2807/dms_contrastive
sbatch run_ddp_test.sh
```

Then monitor with:
```bash
tail -f logs/<jobid>.out
```

Or set up a cron loop to check every 5 min and auto-fix failures.

## What the test does

Runs `run_ddp_test.sh` — a 2-GPU DDP job on `--subsample 0.005` of the full dataset (all 5 selection types), 1 epoch, with LoRA and OHE baseline. On first run it creates a split file at `results/ddp_test/data_split.json`; subsequent runs reuse it for reproducibility.

## Pass criteria

The job must:
1. **Complete without error** (SLURM state: `COMPLETED`, exit code `0:0`)
2. **Report a best val AUC ≥ 0.60** (baseline from job 4419557: **0.6252**)

## Adapting the test for a specific feature

If testing a specific feature (e.g. a new loss function, a new backbone, a new data split), you can modify args in `run_ddp_test.sh` to be relevant to what you're testing. Just be aware that changing AUC-sensitive args (see table below) may make the ≥ 0.60 baseline no longer meaningful — in that case, do a reference run first and update the baseline.

## Key args that affect val AUC

These args in `run_ddp_test.sh` directly influence the reported val AUC — if you change them, the baseline may no longer be meaningful:

| Argument | Value in test | Effect on AUC |
|---|---|---|
| `--subsample` | `0.005` | Smaller = less data = noisier AUC |
| `--model_name` | `esmc` | Architecture; ESM-C 600M backbone |
| `--use_lora` | set | LoRA fine-tuning of ESM backbone; removing it will likely lower AUC |
| `--lora_rank` | `32` | LoRA capacity; lower = less expressive |
| `--hidden_dims` | `512,256,128` | Projection head size |
| `--esm_lr` | `5.75e-5` | ESM backbone learning rate |
| `--learning_rate` | `2.8e-5` | Projection head LR |
| `--num_epochs` | `1` | Only 1 epoch; more epochs would improve AUC |
| `--split_file` | reused after first run | Ensures same train/test split for reproducibility |
| `--selection_types` | all 5 | AUC is averaged across Stability, OrganismalFitness, Binding, Activity, Expression |

## Reference run

- **Job**: 4419557
- **Date**: 2026-03-17
- **Best val AUC**: 0.6252 (step 565, epoch 1)
- **Branch tested**: `fix/ddp-eval-nccl-desync`
- **Split file**: `results/ddp_test/data_split.json`
