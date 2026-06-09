#!/bin/bash
# =============================================================================
# OpenFOAM v2506 — Slurm batch template for hpc01
# Built against the system OpenMPI -> launch with: srun --mpi=pmix
# -----------------------------------------------------------------------------
# Run this from inside your CASE directory (the one with 0/ constant/ system/).
# Edit the marked lines, then:   sbatch openfoam.sh
# =============================================================================
#SBATCH --job-name=openfoam          # <-- name it for your run
#SBATCH --partition=normal
#SBATCH --nodes=1
#SBATCH --ntasks=4                   # <-- MPI ranks = numberOfSubdomains below
#SBATCH --cpus-per-task=1
#SBATCH --time=04:00:00              # <-- walltime ceiling (killed if exceeded)
#SBATCH --output=%x-%j.out           # log: <jobname>-<jobid>.out

set -euo pipefail

source /etc/profile.d/z99-local-modules.sh 2>/dev/null || true
module purge
module load openfoam/v2506

cd "$SLURM_SUBMIT_DIR"               # your case directory

SOLVER=icoFoam                       # <-- your solver (simpleFoam, pimpleFoam, ...)
N=$SLURM_NTASKS

echo "Job $SLURM_JOB_ID on $(hostname) | ranks: $N | $(date)"
which "$SOLVER"

# 1. Mesh (skip if you already have a mesh / use snappyHexMesh separately)
blockMesh

# 2. Decompose into N subdomains (scotch needs no manual geometry).
#    numberOfSubdomains MUST equal --ntasks.
cat > system/decomposeParDict << EOF
FoamFile { version 2.0; format ascii; class dictionary; object decomposeParDict; }
numberOfSubdomains $N;
method scotch;
EOF
decomposePar -force

# 3. Run in parallel (OpenFOAM uses the system OpenMPI -> PMIx)
srun --mpi=pmix -n "$N" "$SOLVER" -parallel

# 4. Merge processor* results back into the case
reconstructPar

echo "Finished at $(date)"
