#!/bin/bash
# ============================================================================
# dfnWorks Slurm template for hpc01
# ----------------------------------------------------------------------------
# Discrete fracture network generation + meshing (LaGriT) + flow (PFLOTRAN)
# + transport (DFNTrans), driven by pydfnworks.
#
# Copy this into your run directory (the one containing driver.py and the
# .in / PTDFN_control.dat input files), adjust as needed, and submit with:
#     sbatch dfnworks.sh
#
# IMPORTANT NOTES
#  * Run dfnWorks through Slurm, NOT interactively — interactive CPU is capped
#    per user, and dfnWorks' pipeline (meshing + PFLOTRAN) wants real cores.
#  * In driver.py, use ncpu=1 for small/moderate networks. The PARALLEL LaGriT
#    merge (ncpu>1) can hang on small problems in this build; serial merge is
#    fast and reliable. Only raise ncpu for genuinely large networks, and test.
#  * dfnWorks calls `mpirun` internally to launch PFLOTRAN — do NOT wrap the
#    python driver in srun. Just run the driver; it manages MPI itself.
# ============================================================================

#SBATCH --job-name=dfnworks
#SBATCH --partition=normal
#SBATCH --nodes=1
#SBATCH --ntasks=1                 # the driver is serial; it spawns PFLOTRAN via mpirun
#SBATCH --cpus-per-task=4          # give the job a few cores for meshing / PFLOTRAN
#SBATCH --time=02:00:00
#SBATCH --output=%x-%j.out         # <jobname>-<jobid>.out

set -euo pipefail

# --- environment ------------------------------------------------------------
source /etc/profile.d/z99-local-modules.sh 2>/dev/null || true
module purge
module load dfnworks/2.7           # sets all the *_EXE / PETSC / PFLOTRAN paths,
                                   # auto-loads openmpi/5.0.10 via depends_on

# pydfnworks needs the conda env ACTIVATED (not just the python binary on PATH)
source /opt/miniforge3/etc/profile.d/conda.sh
conda activate /opt/sw/conda/envs/dfnworks

# Silence harmless PMIx/munge warnings from the MPI PFLOTRAN launch
export PMIX_MCA_psec=native

# --- run --------------------------------------------------------------------
cd "$SLURM_SUBMIT_DIR"

echo "Host: $(hostname)   Job: $SLURM_JOB_ID   Started: $(date)"
echo "PFLOTRAN_EXE=$PFLOTRAN_EXE"
echo "LAGRIT_EXE=$LAGRIT_EXE"

python driver.py

echo "Finished: $(date)"
