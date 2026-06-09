#!/bin/bash
# =============================================================================
# PFLOTRAN — Slurm batch template for hpc01
# Built against the system OpenMPI -> launch with: srun --mpi=pmix
# -----------------------------------------------------------------------------
# Edit the marked lines, then:   sbatch pflotran.sh
# =============================================================================
#SBATCH --job-name=pflotran          # <-- name it for your run
#SBATCH --partition=normal
#SBATCH --nodes=1
#SBATCH --ntasks=8                   # <-- MPI ranks (<= 48); tune to your mesh
#SBATCH --cpus-per-task=1
#SBATCH --time=04:00:00              # <-- walltime ceiling (killed if exceeded)
#SBATCH --output=%x-%j.out           # log: <jobname>-<jobid>.out

set -euo pipefail

# Make 'module' available in the (non-login) batch shell, then load software
source /etc/profile.d/z99-local-modules.sh 2>/dev/null || true
module purge
module load pflotran/6.0

cd "$SLURM_SUBMIT_DIR"               # run from where you submitted (your own dir)

INPUT=input.in                       # <-- your PFLOTRAN input deck

echo "Job $SLURM_JOB_ID on $(hostname) | ranks: $SLURM_NTASKS | $(date)"
which pflotran

# PFLOTRAN uses the system OpenMPI -> PMIx
srun --mpi=pmix -n "$SLURM_NTASKS" pflotran -input_prefix "${INPUT%.in}"

echo "Finished at $(date)"
# Note: decks using a direct (LU) solver only run serially. For parallel runs
# use an iterative-solver deck, or set --ntasks=1 for a direct-solver case.
