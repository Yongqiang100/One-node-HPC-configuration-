#!/bin/bash
# =============================================================================
# DOLFINx + Reaktoro (combined env) — Slurm batch template for hpc01
# For scripts that import BOTH dolfinx AND reaktoro in one process.
# Conda env uses MPICH (NOT system OpenMPI) -> launch with mpirun or --mpi=pmi2
# Do NOT use --mpi=pmix for this env.
# -----------------------------------------------------------------------------
# Edit the marked lines, then:   sbatch dolfinx-reaktoro.sh
# =============================================================================
#SBATCH --job-name=dfx_rkt           # <-- name it for your run
#SBATCH --partition=normal
#SBATCH --nodes=1
#SBATCH --ntasks=38                  # <-- MPI ranks (<= 48); see note below
#SBATCH --cpus-per-task=1
#SBATCH --time=12:00:00              # <-- walltime ceiling (killed if exceeded)
#SBATCH --output=%x-%j.out           # log: <jobname>-<jobid>.out

set -euo pipefail

source /etc/profile.d/z99-local-modules.sh 2>/dev/null || true
module purge
module load dolfinx-reaktoro/2026

cd "$SLURM_SUBMIT_DIR"               # run from where you submitted (your own dir)

SCRIPT=run_study.py                  # <-- your coupled script
ARGS="single"                        # <-- script arguments, if any

# Per-cell Reaktoro equilibrium is heavy; keep each rank single-threaded so the
# ranks don't oversubscribe the 48 cores.
export OMP_NUM_THREADS=1
export OPENBLAS_NUM_THREADS=1
export MKL_NUM_THREADS=1
export EIGEN_NUM_THREADS=1

echo "Job $SLURM_JOB_ID on $(hostname) | ranks: $SLURM_NTASKS | $(date)"
python -c "import dolfinx, reaktoro; print('dolfinx', dolfinx.__version__, '| reaktoro', reaktoro.__version__)"

# Combined env uses MPICH -> use the env's own mpirun (simplest on one node).
# Alternative under Slurm: srun --mpi=pmi2 -n "$SLURM_NTASKS" python "$SCRIPT" $ARGS
mpirun -n "$SLURM_NTASKS" python "$SCRIPT" $ARGS

echo "Finished at $(date)"
# Note on --ntasks: more ranks is not always faster. When per-cell chemistry
# dominates, fewer ranks with more work each can run better — worth a short
# timing test at a couple of rank counts before a long sweep.
