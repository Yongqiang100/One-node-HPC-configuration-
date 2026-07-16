# Slurm job templates — hpc01

One ready-to-edit batch script per installed application. Copy the one you need into your run
directory, edit the lines marked `<--`, and submit with `sbatch`.

```bash
cp ~/slurm-templates/moose.sh ~/runs/myjob/job.sh
cd ~/runs/myjob
# edit job.sh: --job-name, --ntasks, --time, and the INPUT/SCRIPT line
sbatch job.sh
squeue -u $USER        # R = running, PD = pending
tail -f *-*.out        # follow the log
```

## The templates

| File | Module | MPI launcher | Notes |
|---|---|---|---|
| `pflotran.sh` | `pflotran/6.0` | `srun --mpi=pmix` | Direct-solver decks run serially only |
| `moose.sh` | `moose/dev` | `srun --mpi=pmix` | Runs `combined-opt` |
| `openfoam.sh` | `openfoam/v2506` | `srun --mpi=pmix` | Includes decomposePar / reconstructPar |
| `dolfinx.sh` | `dolfinx/2026` | `mpirun` / `srun --mpi=pmi2` | Conda MPICH env |
| `reaktoro.sh` | `reaktoro/2026` | (serial) | One task, no MPI |
| `dolfinx-reaktoro.sh` | `dolfinx-reaktoro/2026` | `mpirun` / `srun --mpi=pmi2` | For scripts using BOTH libraries |
| `phreeqcrm.sh` | `phreeqcrm/3.9.0` + `openmpi/5.0.10` | `srun --mpi=pmix` | Runs YOUR solver that links libPhreeqcRM |
| `dfnworks.sh` | `dfnworks/2.7` | internal `mpirun` | Activate conda env; use `ncpu=1` in driver.py; don't wrap in srun |
| `lammps.sh` | `lammps/stable` | `srun --mpi=pmix` | CPU build (~68 pkgs); MPI and/or OpenMP (`-sf kk`) |
| `lammps-gpu.sh` | `lammps-gpu/stable` | (1 rank/GPU) | GPU build (~69 pkgs, CUDA 13.3); `--gres=gpu:1`; `-sf gpu` or `-sf kk` |

## The one thing to get right: the MPI launcher

The toolchains use two different MPI implementations, so they need different launch flags:

- **PFLOTRAN, MOOSE, OpenFOAM** were built against the **system OpenMPI** → `srun --mpi=pmix`.
- **DOLFINx, Reaktoro, and the combined env** are **conda environments using MPICH** →
  `mpirun -n N …` or `srun --mpi=pmi2`. **Never `--mpi=pmix` for these** — it will fail.

Each template already uses the correct one; this table is just so you know why they differ.

**PhreeqcRM is a library, not a program.** `phreeqcrm.sh` runs *your own solver* that links
`libPhreeqcRM` — replace `./my_solver` with your executable. It was built serial/OpenMP (no internal
MPI), so your solver owns the MPI (system OpenMPI → `srun --mpi=pmix`) and calls PhreeqcRM per-rank.

**dfnWorks manages its own MPI.** `dfnworks.sh` runs `python driver.py`, and dfnWorks calls `mpirun`
*internally* to launch PFLOTRAN — so you do **not** wrap it in `srun`. Two musts: (1) activate the
conda env in the script (`conda activate /opt/sw/conda/envs/dfnworks`), or `import pydfnworks` fails;
(2) set `ncpu=1` in `driver.py` for small/moderate networks — the parallel LaGriT merge can hang.

**LAMMPS: two modules, same input files.** `lammps/stable` (CPU) and `lammps-gpu/stable` (GPU) carry
the same broad package set, so a given input runs under either — only the launch differs. Use the CPU
template for MPI/OpenMP runs; use the GPU template (with `--gres=gpu:1`) to offload to the RTX 4500.
The GPU binary also runs CPU-only if you omit the GPU flags. The node has one GPU, so GPU jobs use one
rank per GPU. Both modules load system Python (not conda), so no conda activation is needed.

## Things common to every template

- `--partition=normal` — the only partition on hpc01.
- `source /etc/profile.d/z99-local-modules.sh` — makes `module` work inside the batch shell (which
  isn't a login shell). Leave it in.
- `cd "$SLURM_SUBMIT_DIR"` — runs the job from the directory you submitted from. **Submit from your
  own run directory** (e.g. `~/runs/myjob`), never from inside `/opt/sw` (read-only — output can't be
  written there).
- `--time` is a hard ceiling: the job is killed if it runs over. Set it a bit above your expected
  runtime.
- `--ntasks` is your core/rank count (max 48). More isn't always faster; for chemistry-heavy work,
  fewer ranks with more work each can win. Don't grab all 48 for a small job — the node is shared.

See the **hpc01 User Guide** for the fuller explanation of modules, directories, and etiquette.
