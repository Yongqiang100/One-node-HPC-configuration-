#!/bin/bash
# =============================================================================
# PhreeqcRM (linked into your solver) — Slurm batch template for hpc01
# -----------------------------------------------------------------------------
# PhreeqcRM is a LIBRARY, not a program. This template runs YOUR solver that
# links libPhreeqcRM. It was built serial/OpenMP (no internal MPI), so the
# coupling pattern is: your solver does the MPI, PhreeqcRM runs per-rank.
#   - Your solver uses the system OpenMPI -> launch with srun --mpi=pmix
#   - Optionally give each rank OpenMP threads for PhreeqcRM's per-cell work
# Edit the marked lines, then:   sbatch phreeqcrm.sh
# =============================================================================
#SBATCH --job-name=rt_phreeqcrm      # <-- name it for your run
#SBATCH --partition=normal
#SBATCH --nodes=1
#SBATCH --ntasks=8                   # <-- MPI ranks (your solver's domains)
#SBATCH --cpus-per-task=1            # <-- OpenMP threads per rank (see note below)
#SBATCH --time=04:00:00              # <-- walltime ceiling (killed if exceeded)
#SBATCH --output=%x-%j.out           # log: <jobname>-<jobid>.out

set -euo pipefail

# Make 'module' available in the (non-login) batch shell, then load software
source /etc/profile.d/z99-local-modules.sh 2>/dev/null || true
module purge
module load openmpi/5.0.10           # your solver's MPI
module load phreeqcrm/3.9.0          # the library (sets LD_LIBRARY_PATH so it's found at runtime)

cd "$SLURM_SUBMIT_DIR"               # run from where you submitted (your own dir)

SOLVER=./my_solver                   # <-- YOUR executable that links libPhreeqcRM
INPUT=input.cfg                      # <-- your solver's input (if any)

# PhreeqcRM per-cell chemistry can use OpenMP within each rank. If you set
# --cpus-per-task > 1 above, expose that many threads here; otherwise keep it 1.
export OMP_NUM_THREADS="${SLURM_CPUS_PER_TASK:-1}"

# Point PhreeqcRM at a database if your solver loads one by name (e.g. phreeqc.dat).
# The module sets $PHREEQCRM_DATABASE to the bundled database directory.
export PHREEQCRM_DATABASE   # already set by the module; exported here for child procs
# If your solver expects the .dat in the working dir, stage it once:
# cp "$PHREEQCRM_DATABASE/phreeqc.dat" .

echo "Job $SLURM_JOB_ID on $(hostname) | ranks: $SLURM_NTASKS | threads/rank: $OMP_NUM_THREADS | $(date)"
ldd "$SOLVER" | grep -i phreeqc || echo "(note: solver does not appear to link libPhreeqcRM)"

# Your solver owns the MPI; PhreeqcRM is serial per rank -> system OpenMPI -> PMIx
srun --mpi=pmix -n "$SLURM_NTASKS" "$SOLVER" "$INPUT"

echo "Finished at $(date)"
# -----------------------------------------------------------------------------
# Note on ranks vs threads: total cores used = ntasks * cpus-per-task <= 48.
#   - Pure MPI:   --ntasks=N  --cpus-per-task=1   (N solver domains)
#   - Hybrid:     --ntasks=N  --cpus-per-task=T   (N domains, T OpenMP threads
#                 each for PhreeqcRM's per-cell solves);  N*T must stay <= 48.
# -----------------------------------------------------------------------------
