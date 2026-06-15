# Using Conda on hpc01

A guide for team members on using the shared conda environments and creating your own. It assumes
you can already log into `hpc01` — see the **hpc01 User Guide** for the basics.

Conda (via Miniforge) is installed at `/opt/miniforge3`. The team's shared environments live under
`/opt/sw/conda/envs/`. You don't manage the install; you just use the shared envs and, when you need
to, create your own in your home directory.

---

## Two ways to use the shared environments

There are two paths, for two different needs. Use whichever fits what you're doing.

### A. `module load` — for running jobs and scripts (recommended)

The shared envs are exposed as **modules**. This is the simplest way to run code and the way the
Slurm job templates use. It puts the environment's `python` and libraries on your path without any
conda setup:

```bash
module load dolfinx-reaktoro/2026
python my_script.py
```

The shared environment modules:

| Module | Contains |
|---|---|
| `dolfinx/2026` | DOLFINx (FEniCSx finite elements) |
| `reaktoro/2026` | Reaktoro (chemical reaction modeling) |
| `dolfinx-reaktoro/2026` | Both DOLFINx and Reaktoro in one env (for scripts importing both) |

These three are **mutually exclusive** — loading one automatically unloads the others (you'll see
*"Lmod is automatically replacing …"*). That's expected. If a single script needs both `import
dolfinx` and `import reaktoro`, load the combined `dolfinx-reaktoro/2026`, not the two separate ones.

For running jobs, this is all you need. You do **not** need `conda activate`.

### B. `conda activate` — for interactive conda work

If you want a real activated conda shell — to use `conda`/`mamba` commands, see the `(env)` prompt, or
work interactively — initialize conda for your shell **once**:

```bash
# check if you're already set up:
grep -q "conda initialize" ~/.bashrc && echo "ready" || /opt/miniforge3/bin/conda init bash
exec bash        # reload your shell after init
```

Then activate a shared env **by its full path** (they're created as path-based envs):

```bash
conda activate /opt/sw/conda/envs/dolfinx-reaktoro
python -c "import dolfinx, reaktoro; print('ok')"
conda deactivate
```

To activate the shared envs by short name instead of full path, register the shared envs directory
once:

```bash
conda config --append envs_dirs /opt/sw/conda/envs
conda activate dolfinx-reaktoro          # now works by name
conda env list                           # shows the shared envs
```

> **The shared envs are read-only to you.** You can activate them and run code, but you cannot
> `conda install` into them — that protects the environment everyone depends on. If you need extra
> packages, make your own env (next section).

---

## Creating your own environment

You can freely create personal conda environments. The one rule: **put them in your home directory**,
because `/opt/sw` is read-only to you. Always use `-p <path>` (a prefix path under your home), never
`-n <name>` (which would try to write into the shared tree).

### Fresh environment

```bash
conda create -p ~/envs/myproject -c conda-forge python=3.12 numpy scipy matplotlib
conda activate ~/envs/myproject
```

### Clone a shared env, then add your own packages

A common, useful pattern — start from a working shared stack and add to it:

```bash
conda create -p ~/envs/mydolfinx --clone /opt/sw/conda/envs/dolfinx-reaktoro
conda activate ~/envs/mydolfinx
conda install -c conda-forge pandas h5py    # your env — you CAN install now
```

Once an env is your own under `~/envs/`, you have full control: `conda install`, `pip install`,
whatever you need, without affecting anyone else.

### Activate your envs by name

Since these are path-based, register your personal envs directory once so you can use short names:

```bash
conda config --append envs_dirs ~/envs
conda activate myproject                     # by name
conda env list                               # lists your envs
```

---

## Using a conda env in a Slurm job

Your own (or a shared) env works in batch jobs. Instead of `module load`, activate the env — but a
batch shell isn't a login shell, so first source conda's setup script:

```bash
#!/bin/bash
#SBATCH --job-name=myjob
#SBATCH --partition=normal
#SBATCH --nodes=1
#SBATCH --ntasks=8
#SBATCH --time=04:00:00
#SBATCH --output=%x-%j.out

# make 'conda' available in the (non-login) batch shell:
source /opt/miniforge3/etc/profile.d/conda.sh
conda activate ~/envs/myproject              # your env (or a shared one by path)

cd "$SLURM_SUBMIT_DIR"

# MPI launcher depends on the env's MPI (see note below):
srun --mpi=pmi2 -n "$SLURM_NTASKS" python my_script.py
```

**Which MPI launcher?** It depends on what MPI is *inside* the env:

- Envs built with conda's **MPICH** (the shared `dolfinx`/`reaktoro`/`dolfinx-reaktoro`, and clones of
  them) → use `mpirun -n N …` or `srun --mpi=pmi2`. **Not** `--mpi=pmix`.
- If you ever build an env against the system OpenMPI → use `srun --mpi=pmix`.
- Serial scripts (e.g. plain Reaktoro) → just `python my_script.py`, no launcher, `--ntasks=1`.

For the shared envs, the ready-made Slurm templates already use the correct launcher — start from
those (`dolfinx.sh`, `reaktoro.sh`, `dolfinx-reaktoro.sh`).

---

## Housekeeping

Conda environments are large — a DOLFINx-class env is several GB, and everyone's home directories
share the same disk on one machine. Be tidy:

```bash
conda env list                       # what you have
conda remove -p ~/envs/old --all     # delete an env you're done with
conda clean --all                    # reclaim cached package downloads
du -sh ~/envs/*                      # see what each env is costing you
```

A few habits that avoid trouble:

- **Stick to `-c conda-forge`.** All the shared envs use conda-forge. Mixing it with the default
  Anaconda channel is the most common cause of broken/slow dependency solves.
- **One env per project**, rather than one giant env you keep adding to — easier to reproduce and to
  delete when finished.
- **Clean up** envs you no longer use; don't let stale multi-GB envs accumulate in your home dir.

---

## When to ask thmc

Personal envs in `~/envs/` are entirely self-service — you don't need anyone's help to create, use, or
delete them.

The one case worth raising with **thmc**: if an environment turns out to be broadly useful to the
whole team, it can be promoted to a **shared module** (built into `/opt/sw/conda/envs/` with a
modulefile, like the existing three) so everyone gets it via `module load`. That keeps the shared set
curated while you stay free to experiment in your own space.

---

## Quick reference

| Task | Command |
|---|---|
| Run code with a shared env (jobs) | `module load dolfinx-reaktoro/2026` |
| Enable `conda activate` (once) | `/opt/miniforge3/bin/conda init bash && exec bash` |
| Activate shared env (by path) | `conda activate /opt/sw/conda/envs/dolfinx-reaktoro` |
| New personal env | `conda create -p ~/envs/NAME -c conda-forge python=3.12 …` |
| Clone a shared env | `conda create -p ~/envs/NAME --clone /opt/sw/conda/envs/dolfinx-reaktoro` |
| Activate by name (after registering) | `conda config --append envs_dirs ~/envs` then `conda activate NAME` |
| List envs | `conda env list` |
| Delete an env | `conda remove -p ~/envs/NAME --all` |
| Reclaim disk | `conda clean --all` |

*Admin contact: **thmc**. For general cluster usage see the hpc01 User Guide; for the installed
scientific software see the admin guide.*
