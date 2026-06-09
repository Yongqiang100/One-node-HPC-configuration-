#!/bin/bash
# =============================================================================
# Reaktoro — Slurm batch template for hpc01
# Reaktoro is SERIAL (no MPI). Use a single task.
# -----------------------------------------------------------------------------
# Edit the marked lines, then:   sbatch reaktoro.sh
# =============================================================================
#SBATCH --job-name=reaktoro          # <-- name it for your run
#SBATCH --partition=normal
#SBATCH --nodes=1
#SBATCH --ntasks=1                   # serial — one task
#SBATCH --cpus-per-task=1            # raise only if your script uses threads
#SBATCH --time=02:00:00              # <-- walltime ceiling (killed if exceeded)
#SBATCH --output=%x-%j.out           # log: <jobname>-<jobid>.out

set -euo pipefail

source /etc/profile.d/z99-local-modules.sh 2>/dev/null || true
module purge
module load reaktoro/2026

cd "$SLURM_SUBMIT_DIR"               # run from where you submitted (your own dir)

SCRIPT=chemistry.py                  # <-- your Reaktoro Python script

echo "Job $SLURM_JOB_ID on $(hostname) | $(date)"
python -c "import reaktoro; print('reaktoro', reaktoro.__version__)"

python "$SCRIPT"

echo "Finished at $(date)"
