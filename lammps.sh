#!/bin/bash
# ============================================================================
# LAMMPS (CPU) Slurm template for hpc01
#   module: lammps/stable   ->  /opt/sw/lammps   (CPU build, ~68 packages)
# ----------------------------------------------------------------------------
# Copy into your run directory (with your input file), adjust, and submit:
#     sbatch lammps.sh
#
# This is the CPU build (broad most.cmake package set: REAXFF, MEAM, ML-*,
# DPD-*, GRANULAR, SPIN, VORONOI, ... — see `lmp -h`). It runs two ways:
#   * MPI  — domain decomposition across ranks   (usually fastest on this node)
#   * OpenMP threads via the KOKKOS host backend  (-k on t N -sf kk)
# For GPU acceleration use the lammps-gpu.sh template (module lammps-gpu/stable).
#
# Pick ONE of the run styles below (comment out the others).
# ============================================================================

#SBATCH --job-name=lammps
#SBATCH --partition=normal
#SBATCH --nodes=1
#SBATCH --ntasks=8                 # MPI ranks  (for the MPI style)
#SBATCH --cpus-per-task=1          # set >1 and ntasks=1 for the OpenMP style
#SBATCH --time=04:00:00
#SBATCH --output=%x-%j.out

set -euo pipefail

source /etc/profile.d/z99-local-modules.sh 2>/dev/null || true
module purge
module load lammps/stable          # auto-loads openmpi/5.0.10 via depends_on

# Silence harmless PMIx/munge warnings from the MPI launch
export PMIX_MCA_psec=native

cd "$SLURM_SUBMIT_DIR"
INPUT=in.lj                        # <-- your LAMMPS input file

echo "Host: $(hostname)  Job: $SLURM_JOB_ID  Started: $(date)"

# --- STYLE 1: MPI (recommended default) -------------------------------------
# Uses $SLURM_NTASKS ranks. System OpenMPI => pmix launcher.
srun --mpi=pmix -n "$SLURM_NTASKS" lmp -in "$INPUT"

# --- STYLE 2: OpenMP threads via KOKKOS (comment out Style 1 to use) ---------
# Set --ntasks=1 and --cpus-per-task=N above, then:
# export OMP_NUM_THREADS="$SLURM_CPUS_PER_TASK"
# lmp -k on t "$SLURM_CPUS_PER_TASK" -sf kk -in "$INPUT"

# --- STYLE 3: MPI + OpenMP hybrid (advanced) --------------------------------
# --ntasks=M --cpus-per-task=T ; total M*T should be <= 48
# export OMP_NUM_THREADS="$SLURM_CPUS_PER_TASK"
# srun --mpi=pmix -n "$SLURM_NTASKS" lmp -k on t "$SLURM_CPUS_PER_TASK" -sf kk -in "$INPUT"

echo "Finished: $(date)"
