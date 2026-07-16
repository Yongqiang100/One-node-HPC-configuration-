#!/bin/bash
# ============================================================================
# LAMMPS (GPU) Slurm template for hpc01
#   module: lammps-gpu/stable  ->  /opt/sw/lammps-gpu  (CUDA 13.3, ~69 packages)
#   GPU: NVIDIA RTX 4500 Ada (compute 8.9 / sm_89)
# ----------------------------------------------------------------------------
# Copy into your run directory (with your input file), adjust, and submit:
#     sbatch lammps-gpu.sh
#
# Same broad package set as the CPU build, PLUS GPU acceleration via two
# backends (choose per run):
#   * GPU package  -sf gpu  -pk gpu 1     (mature, broad pair-style coverage)
#   * KOKKOS/CUDA  -k on g 1 -sf kk       (often faster for large systems)
# It also still runs on CPU if you pass no GPU flags.
#
# The node has ONE GPU, so request exactly one: --gres=gpu:1.
# Pick ONE run style below (comment out the others).
# ============================================================================

#SBATCH --job-name=lammps-gpu
#SBATCH --partition=normal
#SBATCH --nodes=1
#SBATCH --gres=gpu:1               # request the single RTX 4500 Ada
#SBATCH --ntasks=1                 # 1 MPI rank per GPU (see note below)
#SBATCH --cpus-per-task=8          # CPU cores for host-side work / neighbor build
#SBATCH --time=04:00:00
#SBATCH --output=%x-%j.out

set -euo pipefail

source /etc/profile.d/z99-local-modules.sh 2>/dev/null || true
module purge
module load lammps-gpu/stable      # auto-loads openmpi/5.0.10; sets CUDA 13.3 paths

# Silence harmless PMIx/munge warnings from the MPI launch
export PMIX_MCA_psec=native
# Host-side threads (neighbor build, etc.) for the GPU package
export OMP_NUM_THREADS="${SLURM_CPUS_PER_TASK:-8}"

cd "$SLURM_SUBMIT_DIR"
INPUT=in.lj                        # <-- your LAMMPS input file

echo "Host: $(hostname)  Job: $SLURM_JOB_ID  GPU: ${CUDA_VISIBLE_DEVICES:-?}  Started: $(date)"
nvidia-smi --query-gpu=name,memory.used,memory.total --format=csv,noheader || true

# --- STYLE 1: GPU package (recommended default) -----------------------------
# 1 GPU, 1 rank. -pk gpu 1 = use 1 GPU; host neighbor build uses OMP threads.
lmp -sf gpu -pk gpu 1 -in "$INPUT"

# --- STYLE 2: KOKKOS / CUDA (comment out Style 1 to use) --------------------
# 1 MPI rank bound to the GPU. Often faster for large atom counts.
# srun --mpi=pmix -n 1 lmp -k on g 1 -sf kk -in "$INPUT"

# --- STYLE 3: CPU only (no GPU) ---------------------------------------------
# This binary also runs CPU-only; drop --gres and use the lammps.sh style:
# srun --mpi=pmix -n "$SLURM_NTASKS" lmp -in "$INPUT"

echo "Finished: $(date)"

# ----------------------------------------------------------------------------
# NOTES
#  * ONE GPU on this node: request --gres=gpu:1 and use one rank per GPU. The
#    GPU package can share one GPU among a few MPI ranks (e.g. -pk gpu 1 with
#    --ntasks=4) which sometimes helps; KOKKOS prefers exactly 1 rank per GPU.
#  * If a multi-rank KOKKOS/CUDA run segfaults, add "gpu/aware off":
#        lmp -k on g 1 -sf kk -pk kokkos gpu/aware off -in in.file
#    (our MPI is not GPU-aware; only matters with >1 rank.)
#  * Mixed precision (GPU_PREC=mixed) is the build default — good speed/accuracy
#    balance. Verify your model tolerates it if results look off.
#  * GPU jobs are accounted by Slurm like any job (see sacct). Only Slurm jobs
#    are recorded — don't run GPU work interactively.
# ----------------------------------------------------------------------------
