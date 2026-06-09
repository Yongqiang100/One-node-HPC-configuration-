#!/bin/bash
# =============================================================================
# MOOSE (combined-opt) — Slurm batch template for hpc01
# Built against the system OpenMPI -> launch with: srun --mpi=pmix
# -----------------------------------------------------------------------------
# Edit the marked lines, then:   sbatch moose.sh
# =============================================================================
#SBATCH --job-name=moose             # <-- name it for your run
#SBATCH --partition=normal
#SBATCH --nodes=1
#SBATCH --ntasks=8                   # <-- MPI ranks (<= 48); tune to your mesh
#SBATCH --cpus-per-task=1
#SBATCH --time=04:00:00              # <-- walltime ceiling (killed if exceeded)
#SBATCH --output=%x-%j.out           # log: <jobname>-<jobid>.out

set -euo pipefail

source /etc/profile.d/z99-local-modules.sh 2>/dev/null || true
module purge
module load moose/dev

cd "$SLURM_SUBMIT_DIR"               # run from where you submitted (your own dir)

INPUT=input.i                        # <-- your MOOSE input file

echo "Job $SLURM_JOB_ID on $(hostname) | ranks: $SLURM_NTASKS | $(date)"
which combined-opt

# MOOSE uses the system OpenMPI -> PMIx
srun --mpi=pmix -n "$SLURM_NTASKS" combined-opt -i "$INPUT"

echo "Finished at $(date)"
# Tip: if you built a different MOOSE app, replace 'combined-opt' with its binary.
