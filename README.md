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

## The one thing to get right: the MPI launcher

The toolchains use two different MPI implementations, so they need different launch flags:

- **PFLOTRAN, MOOSE, OpenFOAM** were built against the **system OpenMPI** → `srun --mpi=pmix`.
- **DOLFINx, Reaktoro, and the combined env** are **conda environments using MPICH** →
  `mpirun -n N …` or `srun --mpi=pmi2`. **Never `--mpi=pmix` for these** — it will fail.

Each template already uses the correct one; this table is just so you know why they differ.

**PhreeqcRM is a library, not a program.** `phreeqcrm.sh` runs *your own solver* that links
`libPhreeqcRM` — replace `./my_solver` with your executable. It was built serial/OpenMP (no internal
MPI), so your solver owns the MPI (system OpenMPI → `srun --mpi=pmix`) and calls PhreeqcRM per-rank.

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
