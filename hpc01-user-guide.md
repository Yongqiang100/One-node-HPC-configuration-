# hpc01 — User Guide

A short guide for running work on the group's compute server, **hpc01**. It covers logging in,
loading software, and submitting jobs. You don't need admin rights for any of this.

If something here doesn't work, contact **thmc** (the box admin) rather than changing system files —
your account is unprivileged by design, and almost everything you need is already set up.

---

## 1. What the machine is

`hpc01` is a single powerful server (not a multi-node cluster), shared by the team:

- **48 CPU cores**, ~126 GB RAM, one NVIDIA RTX 4500 Ada GPU
- Runs Ubuntu, with the **Slurm** scheduler managing who runs what and when
- Software is provided centrally as **modules** (see §3); you don't install scientific software yourself

Because it's one shared node, you submit jobs to a **queue** rather than just running heavy work
directly — Slurm makes sure two big jobs don't fight over the same cores. Small interactive tests are
fine to run directly; anything long or parallel should go through Slurm (§5).

---

## 2. Logging in

You connect over the team's Tailscale network (ask thmc to be added if you can't reach the box). Once
your laptop is on the tailnet:

```bash
ssh <yourusername>@hpc01
```

No password or key setup is needed if Tailscale SSH is enabled for you — the network handles
authentication. You land in your home directory, `/home/<yourusername>`, which is your private space.

**Your home directory is yours alone.** Other users can't read it. Keep your input files, run
directories, and results here (or under it).

---

## 3. Software: the module system

Scientific software is loaded with **modules**. This keeps versions clean and lets several toolchains
coexist. You don't compile anything — it's already built and shared.

See what's available:

```bash
module avail
```

You'll see the centrally installed applications plus a stack of libraries (compilers, MPI, etc.).
The applications most likely relevant to the group:

| Module | What it is | How to run |
|---|---|---|
| `pflotran/6.0` | Subsurface flow & reactive transport | `pflotran` (MPI) |
| `moose/dev` | MOOSE multiphysics (combined module) | `combined-opt` (MPI) |
| `openfoam/v2506` | OpenFOAM CFD toolbox | `simpleFoam`, `icoFoam`, … (MPI) |
| `dolfinx/2026` | FEniCSx finite elements (Python) | `python …` (MPI) |
| `reaktoro/2026` | Chemical reaction modeling (Python) | `python …` (serial) |
| `dolfinx-reaktoro/2026` | Combined env for scripts needing **both** | `python …` (MPI) |

Load one with:

```bash
module load openfoam/v2506
```

Unload everything and start clean (good habit before switching tools):

```bash
module purge
```

A few things worth knowing:

**The Python modules are mutually exclusive.** `dolfinx/2026`, `reaktoro/2026`, and
`dolfinx-reaktoro/2026` all belong to the same family, so loading one automatically unloads the
others — you'll see a message like *"Lmod is automatically replacing …"*. That's expected. If your
script needs to `import dolfinx` **and** `import reaktoro` in the same program, use the combined
`dolfinx-reaktoro/2026` module, not the two separate ones.

**Module commands need a login shell.** They work normally when you SSH in. Inside a Slurm batch
script (which doesn't get a login shell by default), the script provided in §5 already handles this.

---

## 4. Where to run — use your own directory

**Always run from your own home directory, never from the shared software tree** (`/opt/sw`). The
shared tree is read-only to you, so a job launched there can't write its output and will fail. The
pattern is always: load the module, make a run directory, copy your inputs in, run there.

```bash
module load moose/dev
mkdir -p ~/runs/myjob && cd ~/runs/myjob
cp /path/to/your/input.i .
# ... run here; output lands next to the input ...
```

Copy example/tutorial inputs **into** your run directory rather than running them in place. For
OpenFOAM, copy a whole case folder:

```bash
module load openfoam/v2506
mkdir -p ~/runs/cavity && cd ~/runs/cavity
cp -r "$FOAM_TUTORIALS/incompressible/icoFoam/cavity/cavity" .
cd cavity
```

---

## 5. Running jobs with Slurm

For anything beyond a quick test, submit a **batch job**. You write a small script describing the
resources you need and the command to run, then `sbatch` it. Slurm queues it and runs it when the
node is free.

### A template batch script

Save this as `job.sh` in your run directory and edit the marked lines:

```bash
#!/bin/bash
#SBATCH --job-name=myjob
#SBATCH --partition=normal
#SBATCH --nodes=1
#SBATCH --ntasks=8           # number of MPI ranks (<= 48); tune to your problem
#SBATCH --cpus-per-task=1
#SBATCH --time=04:00:00      # walltime ceiling — job is killed if it exceeds this
#SBATCH --output=%x-%j.out   # log file: <jobname>-<jobid>.out

# Make 'module' work in the batch shell, then load your software
source /etc/profile.d/z99-local-modules.sh 2>/dev/null || true
module purge
module load moose/dev        # <-- your module

cd "$SLURM_SUBMIT_DIR"       # run from where you submitted (your own dir)

# Launch (see the MPI note below for which launcher to use)
srun --mpi=pmix -n "$SLURM_NTASKS" combined-opt -i input.i
```

Submit and watch it:

```bash
sbatch job.sh
squeue -u $USER                          # your jobs: R = running, PD = pending
tail -f myjob-*.out                      # follow the log
scancel <jobid>                          # cancel a job if needed
```

### Which MPI launcher? (important)

Two of the toolchains use **different MPI under the hood**, so they need different `srun` flags:

- **PFLOTRAN, MOOSE, OpenFOAM** — built against the system OpenMPI. Use **`srun --mpi=pmix`**
  (or interactively, `mpirun -n N …`).
- **DOLFINx / Reaktoro / combined** (the conda Python envs) — use the environment's own
  **`mpirun -n N python …`**, or under Slurm **`srun --mpi=pmi2`**. Do **not** use `--mpi=pmix` for
  these; it will fail.

If a parallel job errors immediately with an MPI/PMI message, the launcher flag is the first thing to
check.

### Picking `--ntasks`

`--ntasks` is how many MPI ranks (cores) your job uses, up to 48. More isn't always faster — for some
workloads (especially heavy per-cell chemistry) fewer ranks with more work each runs better. If a job
will be long, it's worth a short test at a couple of rank counts first. Be considerate: the node is
shared, so don't grab all 48 cores for a job that doesn't need them.

---

## 6. Quick interactive test (small only)

For a quick check you can run directly without a batch script — but keep it small and short, since it
competes with queued jobs:

```bash
module load dolfinx-reaktoro/2026
cd ~/runs/test
mpirun -n 4 python my_script.py          # conda env: use mpirun (or srun --mpi=pmi2)
```

For MOOSE/PFLOTRAN/OpenFOAM interactively:

```bash
module load openfoam/v2506
cd ~/runs/cavity/cavity
blockMesh
icoFoam                                  # serial; parallel needs decomposePar first (see §7)
```

---

## 7. OpenFOAM parallel runs (a note)

OpenFOAM splits a mesh across ranks with `decomposePar` before a parallel run, then merges results
with `reconstructPar` after. The number of subdomains must match your rank count. The simplest
decomposition is `scotch` (no manual geometry needed):

```bash
cd ~/runs/cavity/cavity
cat > system/decomposeParDict << 'EOF'
FoamFile { version 2.0; format ascii; class dictionary; object decomposeParDict; }
numberOfSubdomains 4;
method scotch;
EOF
decomposePar -force
mpirun -n 4 icoFoam -parallel             # or: srun --mpi=pmix -n 4 icoFoam -parallel
reconstructPar
```

If `decomposePar` complains about "wrong number of domain divisions", your `numberOfSubdomains`
doesn't match the method — using `method scotch;` as above avoids that.

---

## 8. Etiquette & good habits

- **Run from your own directory**, not `/opt/sw` (§4).
- **Use the queue for heavy work** — submit with `sbatch` rather than running long jobs on the login
  shell, so the scheduler can share the node fairly.
- **Don't request more cores than you need.** 38–48 ranks is reasonable for a genuinely large parallel
  job; small jobs should use fewer.
- **Set a realistic `--time`.** It's a safety ceiling; the job is killed if it runs over. Too short
  loses work, absurdly long ties up the node if something hangs.
- **Clean up old output** before re-running so results don't get mixed, and keep large datasets tidy
  in your home directory.
- **Check `squeue` before launching** a big job to see if someone else is already running — the node
  has 48 cores total, shared across everyone.

---

## 9. Common problems

| Symptom | Likely cause / fix |
|---|---|
| `module: command not found` in a batch job | Add `source /etc/profile.d/z99-local-modules.sh` near the top of the script (the §5 template does this). |
| Parallel job fails instantly with an MPI/PMI error | Wrong launcher. `--mpi=pmix` for MOOSE/PFLOTRAN/OpenFOAM; `--mpi=pmi2` (or `mpirun`) for the DOLFINx/Reaktoro conda envs. |
| `Failed to open file …` / can't write output | You're running inside `/opt/sw` (read-only). Copy inputs to `~/runs/...` and run there. |
| `import dolfinx` and `import reaktoro` can't both load | Load the combined `dolfinx-reaktoro/2026` module, not the two separate ones. |
| Module not found right after it was added | Cache is stale: `module --ignore_cache avail`, or ask thmc. |
| Job stuck in `PD` (pending) | Another job is using the cores. `squeue` shows who; yours runs when the node frees up. |
| Need software that isn't installed | Ask thmc — don't try to install system-wide yourself. |

---

*Admin contact: **thmc**. This guide covers normal user workflows; cluster setup and software
installation are documented separately in the admin guide.*
