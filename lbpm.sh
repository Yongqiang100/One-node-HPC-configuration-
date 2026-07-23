#!/bin/bash
# ============================================================================
# LBPM (GPU) Slurm template for hpc01
#   module: lbpm/1.0  ->  /opt/sw/lbpm   (CUDA 13.3, sm_89)
#   MPI:    openmpi-cuda/5.0.10  (CUDA-aware, UCX cuda_copy/cuda_ipc)
#   GPU:    NVIDIA RTX 4500 Ada
# ----------------------------------------------------------------------------
# LBPM is a lattice-Boltzmann code for porous-media flow. The GPU build passes
# device pointers through MPI, so it REQUIRES the CUDA-aware MPI (loaded by the
# module). Copy into your run directory (with input.db + geometry), edit, submit:
#     sbatch lbpm.sh
#
# The node has ONE GPU. Typical single-node usage is one rank on the GPU. Multi-
# rank runs must match the deck's Domain{ nproc } and share the single GPU.
# ============================================================================

#SBATCH --job-name=lbpm
#SBATCH --partition=normal
#SBATCH --nodes=1
#SBATCH --gres=gpu:1                # the single RTX 4500 Ada
#SBATCH --ntasks=1                  # MPI ranks; must equal product of Domain{nproc}
#SBATCH --cpus-per-task=8           # host threads (analysis/threadpool)
#SBATCH --time=08:00:00
#SBATCH --output=%x-%j.out

set -euo pipefail

source /etc/profile.d/z99-local-modules.sh 2>/dev/null || true
module purge
module load lbpm/1.0               # auto-loads openmpi-cuda/5.0.10, sets CUDA paths

export PMIX_MCA_psec=native
# Force UCX to use the CUDA transports for device buffers (belt-and-suspenders):
export OMPI_MCA_pml=ucx
export UCX_TLS=cuda_copy,cuda_ipc,sm,self

cd "$SLURM_SUBMIT_DIR"
INPUT=input.db                     # <-- your deck (with Domain{ Filename=... })
SIM=lbpm_color_simulator           # <-- or lbpm_permeability_simulator, etc.

echo "Host: $(hostname)  Job: $SLURM_JOB_ID  GPU: ${CUDA_VISIBLE_DEVICES:-?}  $(date)"
nvidia-smi --query-gpu=name,memory.used,memory.total --format=csv,noheader || true

# --- Single-rank GPU (default; simplest, matches Domain{ nproc = 1,1,1 }) -----
# For 1 rank you can run the binary directly (no launcher needed):
"$LBPM_BIN/$SIM" "$INPUT"

# --- Multi-rank GPU (comment out the line above; set --ntasks and nproc) ------
# Domain{ nproc } in the deck must equal --ntasks. All ranks share the 1 GPU.
# srun --mpi=pmix -n "$SLURM_NTASKS" "$LBPM_BIN/$SIM" "$INPUT"

echo "Finished: $(date)"

# ----------------------------------------------------------------------------
# NOTES
#  * Geometry: most decks need a segmented domain. Either a raw file referenced
#    by Domain{ Filename="geom.raw"; n=Nx,Ny,Nz; ReadType="8bit"; ReadValues=... }
#    or a generator script (e.g. CreateBubble.py). Generate BEFORE submitting.
#  * ONE GPU: --gres=gpu:1. Multi-rank shares it (fine for small/medium); it does
#    NOT give more GPU memory. 750^3 won't fit in 24 GB regardless of ranks.
#  * The CUDA-aware MPI is what makes multi-rank GPU halo exchange work. If a
#    multi-rank run ever complains about GPU-aware transport, the UCX_TLS and
#    OMPI_MCA_pml exports above force the right path.
#  * Only Slurm jobs are accounted (sacct). Don't run production interactively.
# ----------------------------------------------------------------------------
