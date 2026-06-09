#!/bin/bash
# =============================================================================
# DOLFINx (FEniCSx) — Slurm batch template for hpc01
# Conda env uses MPICH (NOT system OpenMPI) -> launch with mpirun or --mpi=pmi2
# Do NOT use --mpi=pmix for this env.
# -----------------------------------------------------------------------------
# Edit the marked lines, then:   sbatch dolfinx.sh
# =============================================================================
#SBATCH --job-name=dolfinx           # <-- name it for your run
#SBATCH --partition=normal
#SBATCH --nodes=1
#SBATCH --ntasks=8                   # <-- MPI ranks (<= 48); tune to your mesh
#SBATCH --cpus-per-task=1
#SBATCH --time=04:00:00              # <-- walltime ceiling (killed if exceeded)
#SBATCH --output=%x-%j.out           # log: <jobname>-<jobid>.out

set -euo pipefail

source /etc/profile.d/z99-local-modules.sh 2>/dev/null || true
module purge
module load dolfinx/2026

cd "$SLURM_SUBMIT_DIR"               # run from where you submitted (your own dir)

SCRIPT=model.py                      # <-- your DOLFINx Python script

# Keep each rank single-threaded (avoid oversubscribing the 48 cores)
export OMP_NUM_THREADS=1
export OPENBLAS_NUM_THREADS=1
export MKL_NUM_THREADS=1

echo "Job $SLURM_JOB_ID on $(hostname) | ranks: $SLURM_NTASKS | $(date)"
python -c "import dolfinx; print('dolfinx', dolfinx.__version__)"

# Conda env uses MPICH -> use the env's own mpirun (simplest on one node).
# Alternative under Slurm: srun --mpi=pmi2 -n "$SLURM_NTASKS" python "$SCRIPT"
mpirun -n "$SLURM_NTASKS" python "$SCRIPT"

echo "Finished at $(date)"
