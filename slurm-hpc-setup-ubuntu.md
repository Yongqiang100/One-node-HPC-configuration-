# Single-Node Slurm HPC on Ubuntu — Setup Guide

This builds **one workstation** that acts as both the Slurm **controller** and the only
**compute node**, with:

- **Munge** — authentication (required by Slurm)
- **Slurm** — the job scheduler / workload manager
- **Lmod** — environment modules (`module load ...`)
- **Spack** — managed scientific software stack that auto-generates Lmod modules
- **Compilers + MPI + math libraries**
- **NVIDIA GPU support** via Slurm GRES (Step 14)
- **Remote access for the team** via SSH + VPN (Step 15)
- Optional: **accounting + fairshare**, **scaling to more nodes**
- Worked **application examples** — **PFLOTRAN**, **MOOSE**, and **OpenFOAM** (built against your MPI), **DOLFINx + Reaktoro** (shared conda-env modules), **PhreeqcRM** (a C/C++ library to link into your own solver), **dfnWorks** (discrete fracture networks coupled to PFLOTRAN), **LAMMPS** (molecular dynamics, split CPU and GPU/CUDA modules), and **LBPM** (lattice-Boltzmann porous-media flow, GPU/CUDA — needs a CUDA-aware MPI)

It's intentionally laid out so you can add real compute nodes later with minimal changes.

**Conventions**
- The example hostname is `hpc01` — replace it with yours everywhere.
- Run commands as a `sudo`-capable user.
- Modern Ubuntu uses `/etc/slurm/` (older releases used `/etc/slurm-llnl/`). Check with
  `ls -d /etc/slurm*` and adjust paths if needed.

---

## 0. Plan the layout

- Controller **and** compute live on the same box (no separate login node).
- `/opt` will hold shared software (Spack, modules).
- `/home` is local for now. If you ever add nodes, you'll want `/home` and `/opt`
  shared over NFS (see Optional B).

---

## 1. Base system and developer tools

```bash
sudo apt update && sudo apt -y upgrade
sudo apt install -y \
  build-essential gfortran make cmake git wget curl unzip \
  vim htop tmux pkg-config ca-certificates gnupg lsb-release \
  python3 python3-venv python3-pip
```

---

## 2. Hostname resolution

Slurm needs the node's hostname to resolve. Set it and make sure it's in `/etc/hosts`:

```bash
sudo hostnamectl set-hostname hpc01
hostname            # confirm it prints hpc01
```

Ensure `/etc/hosts` maps the name (Ubuntu usually adds the `127.0.1.1` line; if you have a
fixed IP, prefer that):

```text
127.0.0.1   localhost
127.0.1.1   hpc01
# or, with a static IP:
# 192.168.1.50  hpc01
```

---

## 3. Munge (authentication)

```bash
sudo apt install -y munge libmunge-dev

# Create the key if the package didn't already (check first):
sudo ls -l /etc/munge/munge.key 2>/dev/null || {
  # modern tool:
  sudo /usr/sbin/mungekey --verbose 2>/dev/null || \
  # older tool:
  sudo /usr/sbin/create-munge-key 2>/dev/null || \
  # manual fallback:
  ( sudo dd if=/dev/urandom bs=1 count=1024 of=/etc/munge/munge.key )
}

sudo chown munge: /etc/munge /etc/munge/munge.key
sudo chmod 0700 /etc/munge
sudo chmod 0400 /etc/munge/munge.key

sudo systemctl enable --now munge
```

Verify:

```bash
munge -n | unmunge        # should print STATUS: Success (0)
```

---

## 4. Install Slurm

```bash
sudo apt install -y slurm-wlm slurm-wlm-doc
```

This installs the controller (`slurmctld`), the node daemon (`slurmd`), and client tools
(`sinfo`, `squeue`, `srun`, `sbatch`, `scontrol`, etc.). It also creates the `slurm` user
(confirm with `id slurm`).

**Auto-detect this machine's hardware** — this gives you the exact `NodeName=` line:

```bash
sudo slurmd -C
```

Example output (this box: 1 socket × 24 cores × 2 threads = 48 logical CPUs, ~126 GB RAM):

```text
NodeName=hpc01 CPUs=48 Boards=1 SocketsPerBoard=1 CoresPerSocket=24 ThreadsPerCore=2 RealMemory=125625
```

On an NVIDIA-only machine you may also see a harmless `Exception caught: rsmi_init.` line above
this — that's `slurmd` probing for AMD GPUs and finding none. Ignore it; the config still prints.

Copy everything except the trailing `UpTime=...` — you'll paste it into `slurm.conf` next.
(It's wise to set `RealMemory` slightly *below* the reported value, e.g. round 125625 down to
122000, leaving headroom for the OS.)

---

## 5. slurm.conf

Create the required directories first:

```bash
sudo mkdir -p /var/spool/slurmctld /var/spool/slurmd /var/log/slurm
sudo chown slurm:slurm /var/spool/slurmctld /var/log/slurm
sudo chmod 0755 /var/spool/slurmctld /var/log/slurm
```

Write `/etc/slurm/slurm.conf`:

```ini
# /etc/slurm/slurm.conf
ClusterName=hpc
SlurmctldHost=hpc01

# --- Authentication ---
AuthType=auth/munge
CryptoType=crypto/munge

# --- Resource tracking & enforcement (cgroups) ---
ProctrackType=proctrack/cgroup
TaskPlugin=task/cgroup,task/affinity

# --- Scheduling ---
SchedulerType=sched/backfill
SelectType=select/cons_tres
SelectTypeParameters=CR_Core_Memory
# CR_Core_Memory: allocate whole cores + track memory as a consumable resource.
# Use CR_CPU_Memory instead if you want to schedule by hardware thread.

# --- Daemons / state / logs ---
SlurmUser=slurm
SlurmctldPidFile=/run/slurmctld.pid
SlurmdPidFile=/run/slurmd.pid
SlurmdSpoolDir=/var/spool/slurmd
StateSaveLocation=/var/spool/slurmctld
SlurmctldLogFile=/var/log/slurm/slurmctld.log
SlurmdLogFile=/var/log/slurm/slurmd.log

# --- Timeouts / return-to-service ---
SlurmctldTimeout=120
SlurmdTimeout=300
ReturnToService=2

# --- Compute nodes (paste from `slurmd -C`, set State=UNKNOWN) ---
# (GPU users: Step 14 adds `Gres=gpu:1` to this line.)
NodeName=hpc01 CPUs=48 Sockets=1 CoresPerSocket=24 ThreadsPerCore=2 RealMemory=122000 State=UNKNOWN

# --- Partitions (queues) ---
PartitionName=normal Nodes=ALL Default=YES MaxTime=INFINITE State=UP
```

> The `NodeName=` line above matches your `slurmd -C` output. (If you ever reuse this guide on
> different hardware, swap it for that machine's values.)

---

## 6. cgroup.conf

Write `/etc/slurm/cgroup.conf`:

```ini
# /etc/slurm/cgroup.conf
CgroupPlugin=autodetect
ConstrainCores=yes
ConstrainRAMSpace=yes
ConstrainSwapSpace=yes
ConstrainDevices=yes
```

Modern Ubuntu uses **cgroup v2**, which recent Slurm supports via `autodetect`. Confirm your
system is on v2:

```bash
stat -fc %T /sys/fs/cgroup    # expect: cgroup2fs
```

`ConstrainDevices=yes` is also what isolates the GPU later (Step 14) — only jobs that request
a GPU can see `/dev/nvidia*`.

---

## 7. Start and verify Slurm

```bash
sudo systemctl enable --now slurmctld
sudo systemctl enable --now slurmd
```

Check status and the cluster view:

```bash
systemctl status slurmctld slurmd --no-pager
sinfo
```

If the node shows as `down`, `drained`, or `unk*`, bring it online:

```bash
sudo scontrol update NodeName=hpc01 State=RESUME
sinfo                                  # state should become 'idle'
```

Run a quick interactive test, then a batch test:

```bash
srun -N1 hostname                      # should print hpc01
```

`test.sh`:

```bash
#!/bin/bash
#SBATCH --job-name=hello
#SBATCH --partition=normal
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=2
#SBATCH --mem=1G
#SBATCH --time=00:05:00
#SBATCH --output=hello_%j.out

echo "Running on $(hostname)"
nproc
sleep 20
echo "Done"
```

```bash
sbatch test.sh
squeue
cat hello_*.out
```

---

## 8. Lmod (environment modules)

```bash
sudo apt install -y lmod
```

Lmod installs init scripts into `/etc/profile.d/`, so the `module` command is available in a
**fresh login shell**. Open a new shell and verify:

```bash
module --version
module avail
```

Create a directory for your own/managed modulefiles and make it part of the default search
path system-wide:

```bash
sudo mkdir -p /opt/apps/modulefiles
echo 'module use /opt/apps/modulefiles' | sudo tee /etc/profile.d/z99-modulepath.sh
```

(Spack, below, can populate this for you automatically.)

---

## 9. Spack (managed software stack + auto-generated modules)

Spack builds optimized scientific software and writes Lmod modules so users get a clean
`module load <pkg>` experience. It's optional and builds everything from source, so if you just
need compilers, MPI, and CUDA quickly, the apt packages in Step 10 and the system CUDA in Step 14
are faster — come back to Spack when you want optimized or specific versions.

Clone a **stable release branch** (not `develop`, the unreleased bleeding edge that a plain clone
gives you). As of this writing the current series is `releases/v1.1`; check
<https://github.com/spack/spack/branches> for the latest `releases/vX.Y` and substitute it, or use
`releases/latest` to always pull the newest release:

```bash
sudo git clone -c feature.manyFiles=true --depth=2 --branch=releases/v1.1 \
  https://github.com/spack/spack.git /opt/spack

# Cloning with sudo leaves /opt/spack root-owned, but Spack must NOT run as root and needs to
# write its install tree under $SPACK_ROOT. Hand the tree to your admin user so you can install
# packages without sudo:
sudo chown -R $USER:$USER /opt/spack

# Make `spack` load in every future shell...
echo 'export SPACK_ROOT=/opt/spack' | sudo tee /etc/profile.d/spack.sh
echo 'source /opt/spack/share/spack/setup-env.sh' | sudo tee -a /etc/profile.d/spack.sh

# ...and in the current one (otherwise `spack` is "command not found" until you re-login):
source /etc/profile.d/spack.sh
spack --version          # confirm it's on PATH
```

This is the single-admin model: you own `/opt/spack`, build software and modules, and the team
just `module load`s them. If you instead want several people able to install into the shared
tree, make `/opt/spack` group-writable to a shared group rather than owning it as one user.

Register your system compiler (on Spack 1.x this lands in `packages.yaml`; the old
`compilers.yaml` is gone, but the command is the same):

```bash
spack compiler find
```

**Don't run a blanket `spack external find`.** It also registers system *libraries* (zlib,
openssl, …) as externals, and reusing those is the single biggest source of build failures:
missing `-dev` files, or libraries that live in Ubuntu's multiarch path
(`/usr/lib/x86_64-linux-gnu`) where a package's configure can't find them under `/usr` — giving
errors like `openssl is a must but can not be found` or `zlib library (z) in /usr... not found`.
Let Spack build its own libraries from source instead; they're small and reliable. (If you already
ran `spack external find`, fix it with `spack config edit packages`: delete the library blocks like
`zlib:` and `openssl:`, but keep `gcc:` and tool entries like `cmake:` and `perl:`.)

Then install a package — with the system compiler, not a from-source GCC (building an old GCC on a
recent OS fights the toolchain and is rarely needed):

```bash
spack install openmpi          # built with your system GCC and Spack-built libraries
```

On a very recent release such as Ubuntu 26.04, Spack's package recipes can still lag the system
toolchain, so from-source builds may be bumpy regardless. If you just need MPI/BLAS/FFTW working,
the prebuilt apt packages in **Step 10** are faster and more reliable — keep Spack for the packages
apt doesn't carry, ideally CPU-tuned ones where the optimization is worth the build time.

**Enable Lmod module generation.** Edit `/opt/spack/etc/spack/modules.yaml`:

```yaml
modules:
  default:
    enable:
      - lmod
    lmod:
      hierarchy:
        - mpi
      hash_length: 0
```

Generate/refresh the modulefiles and expose them:

```bash
spack module lmod refresh --delete-tree -y

# Find the generated 'Core' directory (the path contains your arch), then add it:
ls -d /opt/spack/share/spack/lmod/*/Core
echo 'module use /opt/spack/share/spack/lmod/<arch>/Core' | \
  sudo tee /etc/profile.d/z98-spack-modules.sh   # replace <arch> with the real path
```

Now in a fresh shell, `module avail` shows Spack-built software. Full details:
<https://spack.readthedocs.io>.

---

## 10. Compilers, MPI, and math libraries

**Quick path (apt)** — good enough to start:

```bash
sudo apt install -y \
  openmpi-bin libopenmpi-dev \
  libopenblas-dev liblapack-dev libscalapack-openmpi-dev \
  libfftw3-dev
```

**Performance path (Spack)** — build tuned for your CPU and integrate with the modules:

```bash
spack install openmpi %gcc@13
spack install openblas %gcc@13
spack module lmod refresh -y
```

**MPI + Slurm integration.** For `srun` to launch MPI ranks directly, MPI needs PMIx support.
Check what's available and use it explicitly if needed:

```bash
srun --mpi=list                 # see supported PMI types
srun --mpi=pmix -n 4 ./my_mpi_program
```

If the apt OpenMPI lacks tight Slurm/PMIx integration, prefer the Spack-built OpenMPI (which
you can build `+pmix`), or launch with `mpirun` inside an `sbatch` script.

---

## 11. Python (Miniforge / conda)

Recommended: a shared **Miniforge** (conda-forge) install that users activate, plus per-user
environments.

```bash
wget https://github.com/conda-forge/miniforge/releases/latest/download/Miniforge3-Linux-x86_64.sh
sudo bash Miniforge3-Linux-x86_64.sh -b -p /opt/miniforge3
echo 'export PATH=/opt/miniforge3/bin:$PATH' | sudo tee /etc/profile.d/conda.sh
```

Then each user runs `conda create -n myproj python=3.12 ...` for an isolated environment.
(Plain `python3 -m venv` works fine too if you'd rather avoid conda.)

### Optional: a `python/3.14` module for *system* Python

Sometimes you specifically need the **system** interpreter (Ubuntu's `/usr` Python 3.14) rather than
conda — most importantly when *building* software that must link the system `libpython` on the standard
path instead of conda's (the LAMMPS ML-IAP build is a real example; see the LAMMPS section). A small
modulefile makes that explicit and selectable:

```bash
# a shim so bare `python` resolves to system python3 (Ubuntu ships only python3):
sudo mkdir -p /opt/sw/python-system/3.14/bin
sudo ln -sf /usr/bin/python3 /opt/sw/python-system/3.14/bin/python
sudo chmod -R o+rX /opt/sw/python-system

sudo mkdir -p /opt/modulefiles/python
sudo tee /opt/modulefiles/python/3.14.lua > /dev/null << 'EOF'
whatis("Name: Python (system) 3.14 — Ubuntu /usr interpreter + dev libraries (non-conda)")
help([[ System Python 3.14 from /usr (NOT conda). Use for builds that must link the
system libpython. For CMake: -D Python_EXECUTABLE=/usr/bin/python3.
NOTE: an ACTIVATED conda env still wins on PATH; run `conda deactivate` first. ]])
family("python")
prepend_path("PATH", "/opt/sw/python-system/3.14/bin")   -- bare `python`
prepend_path("PATH", "/usr/bin")                          -- `python3`
prepend_path("CPATH", "/usr/include/python3.14")
prepend_path("LIBRARY_PATH", "/usr/lib/x86_64-linux-gnu")
prepend_path("LD_LIBRARY_PATH", "/usr/lib/x86_64-linux-gnu")
prepend_path("PKG_CONFIG_PATH", "/usr/lib/x86_64-linux-gnu/pkgconfig")
setenv("PYTHON", "/usr/bin/python3")
setenv("PYTHON_EXECUTABLE", "/usr/bin/python3")
EOF
```

Caveat, stated plainly: a modulefile **cannot** override an *activated* conda environment — `conda
activate` aggressively front-loads its own `bin` on `PATH`, so `python` will still be conda's until you
`conda deactivate`. The module reliably controls Python only in a clean (non-conda) shell. For the use
case that actually matters — a build linking the right `libpython` — don't rely on `PATH` at all; pass
the explicit CMake hint (`-D Python_EXECUTABLE=/usr/bin/python3`) and strip conda from the build's
`PATH`, as the LAMMPS section does.

---

## 12. Containers (Apptainer)

Use **Apptainer** (formerly Singularity), not Docker, on multi-user HPC: it runs unprivileged,
respects the scheduler, and writes files as the calling user.

```bash
sudo apt install -y software-properties-common
sudo add-apt-repository -y ppa:apptainer/ppa
sudo apt update
sudo apt install -y apptainer
apptainer --version
```

(If the PPA isn't available for your release, grab the `.deb` from the Apptainer GitHub
releases page.) Usage example:

```bash
srun apptainer exec docker://ubuntu:24.04 cat /etc/os-release
```

For GPU containers, add `--nv` so Apptainer injects the NVIDIA driver:

```bash
srun --gres=gpu:1 apptainer exec --nv docker://nvidia/cuda:12.4.1-base-ubuntu24.04 nvidia-smi
```

---

## 13. Adding team members

Each member needs a Linux account on the box (Slurm authorizes against these) plus a way to log
in. Repeat this per person — shown here for `bob`:

**1. Create the account** (prompts for a password and full name):

```bash
sudo adduser bob
# optional: put everyone in a shared group
sudo groupadd -f researchers
sudo usermod -aG researchers bob
```

**2. Install their SSH key.** Password SSH login is disabled (Step 15.4), so members log in with
keys. Have each person generate one on their *own* machine (`ssh-keygen -t ed25519`) and send you
the resulting `~/.ssh/id_ed25519.pub`; then install it:

```bash
sudo -u bob mkdir -p /home/bob/.ssh
sudo -u bob tee -a /home/bob/.ssh/authorized_keys < bob_key.pub
sudo chmod 700 /home/bob/.ssh
sudo chmod 600 /home/bob/.ssh/authorized_keys
```

**3. Remote access (if they're off-site).** Add them to Tailscale (Step 15.3): if they share your
email domain they join the tailnet just by signing in; otherwise send an invite from the admin
console. On the same LAN, skip this — the account plus key is enough.

**4. Slurm accounting (only if you set up Optional A).** With slurmdbd in place, register them so
usage is tracked and fairshare applies:

```bash
sudo sacctmgr -i add user bob account=researchers
```

Without accounting there's nothing else to do Slurm-side — any account on the box can submit.

**Verify.** The member connects (`ssh bob@hpc01` on the LAN, or the Tailscale name remotely), gets
`module` automatically in their login shell, and runs work:

```bash
sbatch myjob.sh                                # batch job
srun --pty bash                                # interactive shell inside an allocation
srun --gres=gpu:1 nvidia-smi                   # if they need the GPU
```

---

## 14. NVIDIA GPU support (Slurm GRES)

For a workstation with an NVIDIA GPU (e.g. an **RTX 4500 Ada**, 24 GB). Three parts: install
the driver, install the CUDA toolkit, then register the GPU with Slurm.

### 14.1 Install the NVIDIA driver

Let Ubuntu pick the branch and keep it under apt/DKMS — the lowest-friction, recommended path:

```bash
sudo apt update
sudo apt install -y ubuntu-drivers-common
ubuntu-drivers devices          # confirm the GPU + a 'recommended' branch
sudo ubuntu-drivers install
sudo reboot
```

After reboot, `nvidia-smi` should list the card and a driver version.

- Current production branches (57x–59x) all support Ada. From branch 590 onward the package
  is just `nvidia-driver` (no number), with separate pinning packages to lock a version.
- **Secure Boot** is the most common reason `nvidia-smi` fails after install: the DKMS module
  must be signed. The installer prompts for a MOK password; finish enrollment in the blue
  "MOK Management" screen on the next reboot (or disable Secure Boot in firmware).
- **Headless box** (no monitor): use the compute/server variant to skip the display stack —
  `nvidia-headless-*` + `nvidia-utils-*`, or the `-server` metapackages.

### 14.2 CUDA toolkit

Add NVIDIA's repo for the toolkit. The versioned `cuda-toolkit-12-x` metapackage installs the
compiler and libraries **without** touching your driver, so the two don't conflict:

```bash
# Replace ubuntu2404 with your release (ubuntu2604, ubuntu2204, ...)
wget https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2404/x86_64/cuda-keyring_1.1-1_all.deb
sudo dpkg -i cuda-keyring_1.1-1_all.deb
sudo apt update
apt-cache search cuda-toolkit | grep '^cuda-toolkit-12'   # list available 12.x versions
sudo apt install -y cuda-toolkit-12-X                      # use the highest one listed
```

Put it on PATH:

```bash
echo 'export PATH=/usr/local/cuda/bin:$PATH'                        | sudo tee    /etc/profile.d/cuda.sh
echo 'export LD_LIBRARY_PATH=/usr/local/cuda/lib64:$LD_LIBRARY_PATH' | sudo tee -a /etc/profile.d/cuda.sh
```

Verify in a fresh shell with `nvcc --version`. Or, to manage CUDA versions cleanly, install it
through Spack as a module instead:

```bash
spack install cuda
spack module lmod refresh -y
# then: module load cuda
```

### 14.3 Register the GPU with Slurm

**Do not use `AutoDetect=nvml`.** The packaged Ubuntu `slurm-wlm` is not compiled against
NVIDIA's NVML library, so autodetect aborts `slurmd` with a fatal *"we weren't able to find
that lib when Slurm was configured"* error. (Autodetect requires building Slurm from source
with `--with-nvml`, which isn't worth it for one card.) Define the GPU explicitly.

Create `/etc/slurm/gres.conf`:

```ini
# /etc/slurm/gres.conf
Name=gpu File=/dev/nvidia0
```

Edit `/etc/slurm/slurm.conf` — add the GRES type and annotate the node:

```ini
GresTypes=gpu

# EDIT your existing NodeName line to add `Gres=gpu:1` — do NOT add a second NodeName line.
# (Two NodeName entries for the same host make slurmctld/slurmd abort: "Duplicated NodeName".)
NodeName=hpc01 CPUs=48 Sockets=1 CoresPerSocket=24 ThreadsPerCore=2 RealMemory=122000 Gres=gpu:1 State=UNKNOWN
```

Do **not** add `AccountingStorageTRES=gres/gpu` here. That enables GPU-hour *accounting*, which
requires slurmdbd — without it, slurmctld aborts with "slurmdbd is required to run with TRES
gres/gpu." It belongs with the accounting setup in Optional A, not here. GPU *scheduling* needs
only `GresTypes=gpu`, the `Gres=gpu:1` on the node line, and `gres.conf`.

Your `cgroup.conf` already has `ConstrainDevices=yes` (Step 6) — that's what hides the GPU
from jobs that didn't request it.

### 14.4 Restart and verify

```bash
sudo systemctl restart slurmctld slurmd
sudo scontrol update NodeName=hpc01 State=RESUME      # if it dropped into drain
scontrol show node hpc01 | grep -i gres               # expect: Gres=gpu:1
```

Test both allocation and isolation:

```bash
srun --gres=gpu:1 nvidia-smi      # sees the GPU
srun nvidia-smi                   # should NOT see it — no GPU requested
```

The second command coming up empty proves device isolation works: a job only gets the card
when it asks.

### 14.5 Sharing one GPU across the team

With the config above the GPU is allocated **exclusively** — one GPU job runs, the rest queue.
Predictable, and correct if each job wants the whole card.

For many *light* GPU jobs (notebooks, inference, dev) that you'd rather pack onto the card,
add **sharding**:

```ini
# slurm.conf
GresTypes=gpu,shard
NodeName=hpc01 ... Gres=gpu:1,shard:8 State=UNKNOWN    # up to 8 concurrent jobs
```
```ini
# gres.conf
Name=gpu   File=/dev/nvidia0
Name=shard Count=8 File=/dev/nvidia0
```

Users then request `--gres=shard:2` instead of a whole GPU. Caveat: shards share the card's
memory and compute cooperatively — there is no hard per-job VRAM cap, so it's great for light
or interactive work but wrong for jobs that each need all 24 GB. (CUDA MPS is the managed
alternative, but it's noticeably more setup.)

---

## 15. Remote access for team members

The foundation is SSH. Two variables shape the rest: **where** people connect from (same LAN
vs. off-site) and **how** they authenticate (keys, not passwords).

### 15.1 SSH server + a stable address

If this was a Desktop install, the SSH server may not be present yet:

```bash
sudo apt update
sudo apt install -y openssh-server avahi-daemon
sudo systemctl enable --now ssh
hostname -I        # the LAN address, e.g. 192.168.1.50
```

On the LAN a member with an account can already connect:

```bash
ssh alice@192.168.1.50
ssh alice@hpc01.local        # via avahi/mDNS
```

Pin the address so it doesn't move: set a **DHCP reservation** for the workstation's MAC on
the router (easiest), or give it a static IP via netplan. A drifting IP is the usual
"I can't connect today" culprit.

### 15.2 Key-based login for each member

Each member, on *their own* machine, makes a keypair once:

```bash
ssh-keygen -t ed25519 -C "alice@laptop"
```

Then installs the public key on the workstation. Simplest, while password login is still on:

```bash
ssh-copy-id alice@hpc01.local
```

Or do it for them — append their `id_ed25519.pub` to `~/.ssh/authorized_keys`:

```bash
sudo -u alice mkdir -p /home/alice/.ssh
sudo -u alice tee -a /home/alice/.ssh/authorized_keys < alice_key.pub
sudo chmod 700 /home/alice/.ssh
sudo chmod 600 /home/alice/.ssh/authorized_keys
```

### 15.3 Reaching it from off-site

**Same office network** → the LAN address from 15.1 is enough; skip to 15.4.

**From home/elsewhere** → don't expose SSH to the open internet. The easiest secure option for
a small team is a mesh VPN — **Tailscale** (WireGuard under the hood, works through NAT with
no router config):

```bash
# on the workstation:
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up
tailscale ip -4        # the 100.x.y.z address members will use
```

**Register the workstation as a tagged server, not a personal device.** That plain `tailscale up`
ties the machine to whoever logged in. For a shared box, make it owned by a tag instead — tagged
nodes don't expire and don't depend on any one person's account:

1. **Declare the tag** in the policy file (admin console → **Access Controls**). You must be a
   tagOwner of a tag before you can apply it:
   ```json
   {
     "tagOwners": {
       "tag:server": ["autogroup:admin"]
     }
   }
   ```
2. **Generate an auth key** (admin console → **Settings → Keys → Generate auth key**): set an
   expiry, leave **Ephemeral off** (a server should persist), enable **Tags**, and select
   `tag:server`. A one-off key is fine for a single machine; use a reusable key for several.
   Treat the key (`tskey-auth-...`) like a password.
3. **Bring the box up with the key** instead of an interactive login:
   ```bash
   sudo tailscale up --auth-key=tskey-auth-xxxxxxxxxxxx --ssh
   # if the key was created without a tag, also add: --advertise-tags=tag:server
   ```

To convert a machine you already brought up under a personal login, open the **Machines** page
in the admin console, find it, and edit its ACL tags to add `tag:server` — that reassigns
ownership to the tag without touching the box. (One-off keys are auto-revoked once used; auth
keys themselves cap at a 90-day expiry — use an OAuth client with the `auth_keys` scope for
regular re-provisioning — but a key expiring never disconnects an already-registered node.)

Each member installs Tailscale, signs into the same tailnet, then connects from anywhere:

```bash
ssh alice@hpc01        # MagicDNS name, or the 100.x.y.z address
```

No ports opened to the internet, everything encrypted. Self-hosted alternatives: plain
WireGuard, or Headscale. On a university/company network, members may instead VPN into the
institution first, then SSH to the LAN address.

Fallback without a VPN: router port-forwarding (an external port → the workstation's `22`) —
but only with keys-only auth + fail2ban + a non-default port, since it puts SSH on the public
internet.

### 15.4 Lock it down

Put overrides in a drop-in so package upgrades don't clobber them — create
`/etc/ssh/sshd_config.d/99-hardening.conf`:

```text
PermitRootLogin no
PubkeyAuthentication yes
PasswordAuthentication no
```

> **Confirm key login works in a separate terminal before applying this**, or you can lock
> yourself out. Then restart:

```bash
sudo systemctl restart ssh
```

Firewall — add the SSH rule **before** enabling, or you'll cut your own session:

```bash
sudo ufw allow OpenSSH
sudo ufw enable
sudo ufw status
```

Ban brute-force attempts and keep the box patched:

```bash
sudo apt install -y fail2ban unattended-upgrades
sudo systemctl enable --now fail2ban
sudo fail2ban-client status sshd
```

### 15.5 Convenience tools

A `~/.ssh/config` entry on each member's machine turns connecting (ssh, scp, rsync, VS Code)
into one word:

```text
Host hpc01
    HostName 100.x.y.z        # Tailscale IP, hpc01.local, or public IP
    User alice
```

Now `ssh hpc01` just works, and:

- **VS Code "Remote - SSH"**: connect to `hpc01` and edit/run on the box as if local.
- **File transfer**: `scp file hpc01:~/` for one-offs; `rsync -avP localdir/ hpc01:~/dest/`
  for large or resumable transfers.
- **Jupyter on the GPU** — start it on the box and tunnel the port rather than exposing it:

  ```bash
  # on hpc01, inside a Slurm allocation so it uses the scheduler:
  srun --gres=gpu:1 --cpus-per-task=8 --mem=32G --pty jupyter lab --no-browser --port=8888
  # on the laptop:
  ssh -L 8888:localhost:8888 hpc01
  ```

  then open `localhost:8888`. For a real multi-user setup, **JupyterHub** gives each person
  their own web login and can launch notebooks as Slurm jobs.

### 15.6 Use Slurm for compute, not the login shell

Because this is a single node, an SSH session drops members onto the *same* machine that runs
jobs. They should **not** run heavy compute directly in that login shell — that bypasses Slurm
and lets people collide on the CPUs and the single GPU. Instead:

```bash
sbatch job.sh                                                # batch work
srun --gres=gpu:1 --cpus-per-task=8 --mem=32G --pty bash     # interactive shell in an allocation
```

The second command gives an interactive prompt that lives *inside* a Slurm allocation, so the
person's GPU and CPU use is scheduled and bounded — the whole reason Slurm is on the machine.

---

## Optional A — Accounting + job history (and optional fairshare)

This gives you a persistent, queryable **job history** — who ran what, when, for how long, with what
CPU and memory — via `sacct` and `sreport`. It's the `slurmdbd` accounting daemon writing job records
into a **MariaDB** database. The same database is also the prerequisite for fairshare and per-user
limits later, so set it up once even if you only want history now.

There are two levels: a weak flat-file mode (`accounting_storage/filetxt`) and the real thing
(`slurmdbd` + MariaDB). Use the real thing — it's the standard and barely more work.

### A.1 Install MariaDB and slurmdbd

```bash
sudo apt update
sudo apt install -y mariadb-server slurmdbd
sudo systemctl enable --now mariadb
```

### A.2 Create the accounting database and DB user

Choose a password and use the **same** string here and in `slurmdbd.conf` (A.3). It's a localhost-only
DB account, but keep it out of shell history / shared notes.

```bash
sudo mysql << 'SQL'
CREATE DATABASE IF NOT EXISTS slurm_acct_db;
CREATE USER IF NOT EXISTS 'slurm'@'localhost' IDENTIFIED BY '<DB_PASSWORD>';
GRANT ALL PRIVILEGES ON slurm_acct_db.* TO 'slurm'@'localhost';
FLUSH PRIVILEGES;
SQL
```

> **Gotcha #1 — the password must match.** The single most common failure is creating the DB user with
> one password and writing a different one into `slurmdbd.conf`. slurmdbd then loops forever with
> `error: mysql_real_connect failed: 1045 Access denied for user 'slurm'@'localhost'` and never opens
> its port (so slurmctld/sacctmgr get *"Connection refused"* on 6819). If you hit this, fix the DB side
> to match the conf and restart slurmdbd:
> ```bash
> sudo mysql -e "ALTER USER 'slurm'@'localhost' IDENTIFIED BY '<DB_PASSWORD>'; FLUSH PRIVILEGES;"
> sudo systemctl restart slurmdbd
> ```

### A.3 Configure slurmdbd

```bash
sudo tee /etc/slurm/slurmdbd.conf > /dev/null << 'EOF'
DbdHost=localhost
DbdPort=6819
SlurmUser=slurm
DebugLevel=info
LogFile=/var/log/slurm/slurmdbd.log
PidFile=/run/slurmdbd.pid

StorageType=accounting_storage/mysql
StorageHost=localhost
StoragePort=3306
StorageUser=slurm
StoragePass=<DB_PASSWORD>
StorageLoc=slurm_acct_db
EOF

# slurmdbd.conf holds the DB password — it MUST be 0600 and slurm-owned,
# or slurmdbd refuses to start.
sudo chown slurm:slurm /etc/slurm/slurmdbd.conf
sudo chmod 600 /etc/slurm/slurmdbd.conf
sudo mkdir -p /var/log/slurm && sudo chown slurm:slurm /var/log/slurm

sudo systemctl enable --now slurmdbd
sudo tail -5 /var/log/slurm/slurmdbd.log     # should show a clean MySQL connect, no "Access denied"
sudo ss -tlnp | grep 6819                     # slurmdbd LISTENing = healthy
```

### A.4 Point slurm.conf at slurmdbd

Edit **`/etc/slurm/slurm.conf`** and add the accounting lines. `ClusterName` is already set near the
top of the file from Step 5 — note its value (e.g. `hpc`) and do **not** add a second one.

```bash
sudo tee -a /etc/slurm/slurm.conf > /dev/null << 'EOF'

# --- Accounting (slurmdbd + MariaDB) ---
AccountingStorageType=accounting_storage/slurmdbd
AccountingStorageHost=localhost
AccountingStoragePort=6819
JobAcctGatherType=jobacct_gather/cgroup
JobAcctGatherFrequency=30
EOF

sudo systemctl restart slurmctld
scontrol show config | grep -i accountingstoragetype    # → accounting_storage/slurmdbd
```

> **Gotcha #2 — edit the file, don't paste into the shell.** The accounting lines must go *into*
> `slurm.conf`. Typing them at the bash prompt just runs them as (failing) commands and changes
> nothing — the symptom is `sacctmgr` reporting *"You are not running a supported accounting_storage
> plugin"* because slurmctld never picked up the config. Use the `tee -a` above (or a real editor) and
> confirm with the `scontrol show config` check.
>
> `JobAcctGatherType=jobacct_gather/cgroup` is what captures per-job **memory** (`MaxRSS`); without it
> you get timing and CPU but no memory high-water mark.

### A.5 Register the cluster, account, and users

The cluster name here **must exactly match `ClusterName` in slurm.conf** (here `hpc`). A mismatch makes
slurmctld unable to store records.

```bash
sudo sacctmgr -i add cluster hpc
sudo sacctmgr -i add account researchers Description="Research group" Organization=lab
sudo sacctmgr -i add user thmc    account=researchers
sudo sacctmgr -i add user chen    account=researchers
sudo sacctmgr -i add user calo    account=researchers
sudo sacctmgr -i add user hussain account=researchers

sacctmgr show associations format=Cluster,Account,User    # verify the mapping
```

### A.6 Verify end-to-end

```bash
sbatch --wrap='sleep 20; echo done' --job-name=acct-test
# after it runs (give it time if the node is busy):
sacct -X --format=JobID,JobName,User,State,Elapsed,AllocCPUS,Start,End
sacct -j <jobid> --format=JobID,JobName,MaxRSS,Elapsed,State    # MaxRSS shows on the .batch step
```

A job appearing as `COMPLETED` with elapsed time and timestamps means accounting is live and recording.

### A.7 Querying the job history (day to day)

```bash
# sacct — job records
sacct -X -S today                                            # today (one line per job)
sacct -X -S 2026-06-01 -E now                                # a date range
sacct -u calo --format=JobID,JobName,Elapsed,MaxRSS,State    # one user
sacct -j 1234                                                # one job (step detail incl. MaxRSS)

# sreport — aggregate usage
sreport cluster utilization start=2026-06-01 end=now         # node utilization
sreport user top start=2026-06-01 end=now TopCount=10        # top users by usage
sreport cluster AccountUtilizationByUser start=2026-06-01 end=now
```

`-X` collapses the per-step `.batch`/`.extern` rows into one line per job; drop it for step-level
detail (where `MaxRSS` lives).

### What is and isn't captured

- **Only Slurm jobs are accounted.** Interactive work run outside the scheduler (a bare `python` or
  `mpirun` on the shell) never appears in `sacct`/`sreport`. This is inherent to Slurm accounting — and
  a further reason to push heavy work through `sbatch`: queued jobs get recorded and attributed;
  interactive work is invisible to history and reporting.
- Records persist indefinitely by default; the DB grows slowly on one node. `sacctmgr archive` exists
  if you ever want to prune.

### Optional — turn on fairshare / limits later

Accounting as set up above is **record-only** (`AccountingStorageEnforce` defaults to `none`) — correct
for pure history. To later *enforce* fairshare or per-user/account limits on top of the same database,
add to `slurm.conf` and restart slurmctld:

```ini
PriorityType=priority/multifactor
PriorityWeightFairshare=100000
AccountingStorageEnforce=associations,limits
```

(If you added the GPU in Step 14 and want GPU-hours tracked, also set
`AccountingStorageTRES=gres/gpu` — this is the setup that satisfies the "slurmdbd is required for TRES
gres/gpu" requirement noted in Step 14.)

---

## Optional B — Scaling to multiple nodes later

When you add a second machine (`hpc02`):

1. **Shared storage:** export `/home` and `/opt` from `hpc01` over NFS; mount on `hpc02`.
2. **Auth:** copy `/etc/munge/munge.key` from `hpc01` to `hpc02` (same perms), restart munge
   on both.
3. **Config:** copy `slurm.conf`, `cgroup.conf` (and `gres.conf`) to `hpc02` — every node uses
   an identical `slurm.conf`.
4. **Add the node** in `slurm.conf` and reload:
   ```ini
   NodeName=hpc02 CPUs=... Sockets=... ... State=UNKNOWN
   PartitionName=normal Nodes=hpc01,hpc02 Default=YES MaxTime=INFINITE State=UP
   ```
   ```bash
   sudo scontrol reconfigure
   ```
5. **Firewall:** if enabled, open Slurm ports between nodes — `6817/tcp` (slurmctld),
   `6818/tcp` (slurmd), `6819/tcp` (slurmdbd).
6. On `hpc02`, install `slurm-wlm` + `munge` and start only `slurmd`.

---

## Application software (built in the shared `/opt/sw` tree)

Build application software in a shared, world-readable tree — **`/opt/sw`** — so the whole team can
load it through modules, rather than it living in one person's home directory. Create it once, owned
by the admin so you can build without `sudo`:

```bash
sudo mkdir -p /opt/sw && sudo chown $USER:$USER /opt/sw && sudo chmod 755 /opt/sw
sudo chmod -R o+rX /opt/spack          # OpenMPI etc. — every app module depends_on this
```

Build **in this final location**: PETSc, libMesh, and MOOSE bake absolute paths (PETSC_DIR, rpaths)
into the build, so a finished build can't be relocated by moving it — pick the path up front. Start
each build from a clean shell so stale paths don't leak in:

```bash
module purge
unset PETSC_DIR PETSC_ARCH
spack load openmpi
```

The two worked examples below build into `/opt/sw`; see **Shared software layout** at the end for the
team-access details (module visibility, run-from-your-own-directory, verification).

> **Optional — personal build.** If you only want an install for yourself, you can build under your
> home directory instead (e.g. `~/software`, `~/projects`) by substituting those paths below. It
> won't be readable by the team, so `/opt/sw` is the default here.

---

## Application example — PFLOTRAN (manual build + Lmod module)

A worked example of putting a real parallel code on this stack. **PFLOTRAN** (subsurface flow +
reactive transport) is essentially **PETSc + MPI + HDF5**; the only part that reliably bites is
matching the PETSc version. The current release (**v6.0**) pins **PETSc v3.24.5**.

### Route 1 — Spack (quick)

```bash
spack install pflotran        # resolves a matched PFLOTRAN + PETSc + HDF5 + OpenMPI set
spack load pflotran
```

One command, fully reproducible. As of this writing the Spack package tops out at **PFLOTRAN
5.0.0** (paired with PETSc 3.21.6) — check `spack versions pflotran`. Use this unless you need v6.0.

### Route 2 — Manual build against your OpenMPI (pinned v6.0, best Slurm integration)

The canonical, supported route; it ties PFLOTRAN to the same OpenMPI that Slurm launches with
(`srun --mpi=pmix`).

**1. Activate the MPI to build against** (keep it loaded for the whole build):

```bash
spack load openmpi
which mpicc mpif90            # must resolve into your Spack OpenMPI
cd /opt/sw
```

**2. Build PETSc v3.24.5** (uses your MPI; lets PETSc fetch the numerical libraries):

```bash
git clone https://gitlab.com/petsc/petsc
cd petsc
git checkout v3.24.5

./configure \
  --with-cc=mpicc --with-cxx=mpicxx --with-fc=mpif90 \
  --COPTFLAGS='-O3 -march=znver4' \
  --CXXOPTFLAGS='-O3 -march=znver4' \
  --FOPTFLAGS='-O3 -march=znver4 -Wno-unused-function' \
  --with-debugging=0 \
  --download-hdf5=yes --download-hdf5-fortran-bindings=yes \
  --download-fblaslapack=yes \
  --download-metis=yes --download-parmetis=yes
```

Run the `make … all` line that configure prints at the end, then optionally `make … check`.

**3. Export the two variables PFLOTRAN's build needs** (in this build shell; use the *actual*
`PETSC_ARCH` from the configure output — the runtime doesn't need them, since PFLOTRAN is rpath'd to PETSc):

```bash
export PETSC_DIR=/opt/sw/petsc
export PETSC_ARCH=arch-linux-c-opt
```

**4. Build PFLOTRAN:**

```bash
cd /opt/sw
git clone https://bitbucket.org/pflotran/pflotran      # mirror: github.com/petsc/pflotran
cd pflotran/src/pflotran
make pflotran                                           # produces ./pflotran
```

**5. Test through Slurm:**

```bash
export PMIX_MCA_psec=native   # silences a harmless PMIx "psec/munge" warning

# parallel run — a deck built for MPI (the -npN naming) uses an iterative solver:
srun --mpi=pmix -n 4 ./pflotran \
  -pflotranin /opt/sw/pflotran/regression_tests/default/srcsink_sandbox/srcsink_sandbox_pressure-np4.in
```

A run that ends with a `Wall Clock Time` line succeeded.

**Solver gotcha:** some decks (e.g. the `inversion/` cases) request a **direct solver** (`PCLU`),
which PETSc's built-in LU supports **serially only** — these error with *"Direct solver not
supported when running in parallel"*. Run them on `-n 1`, or use a deck with an iterative solver.
If you genuinely need a parallel direct solve, rebuild PETSc adding
`--download-mumps=yes --download-scalapack=yes`.

### Expose it as an Lmod module

```bash
sudo mkdir -p /opt/modulefiles/pflotran
sudo tee /opt/modulefiles/pflotran/6.0.lua > /dev/null << 'EOF'
-- -*- lua -*-
whatis("Name: PFLOTRAN")
whatis("Version: 6.0")
whatis("Description: Massively parallel subsurface flow and reactive transport")

help([[ PFLOTRAN, built against Spack OpenMPI 5.0.10 + PETSc 3.24.5.
Run: srun --mpi=pmix -n N pflotran -pflotranin <deck>.in ]])

-- adjust these two paths if you built elsewhere
local pflotran_bin = "/opt/sw/pflotran/src/pflotran"
local petsc_lib    = "/opt/sw/petsc/arch-linux-c-opt/lib"

depends_on("openmpi")                          -- the MPI it was compiled with
prepend_path("PATH",            pflotran_bin)
prepend_path("LD_LIBRARY_PATH", petsc_lib)     -- petsc + bundled hdf5/metis/parmetis libs
setenv("PMIX_MCA_psec", "native")              -- quiets the PMIx munge warning
EOF
```

Put the directory on `MODULEPATH` for all users (named `z99` so it runs after Lmod/Spack init):

```bash
echo 'module use /opt/modulefiles' | sudo tee /etc/profile.d/z99-local-modules.sh
```

Open a new login shell, then:

```bash
module load pflotran/6.0
# `pflotran` is now on PATH; OpenMPI and the psec setting are handled by the module:
srun --mpi=pmix -n 4 pflotran -pflotranin <deck>.in
```

### Batch script template

```bash
#!/bin/bash
#SBATCH --job-name=pflotran
#SBATCH --ntasks=4
#SBATCH --output=%x-%j.out

source /opt/spack/share/spack/setup-env.sh   # make `spack`/`module` available in the non-login job shell
module load pflotran/6.0                      # or: spack load openmpi && export PMIX_MCA_psec=native

srun --mpi=pmix pflotran -pflotranin /path/to/model.in
```

**Team access:** because this builds into `/opt/sw` with its modulefile in `/opt/modulefiles`, the
whole team can `module load pflotran` once the shared tree is readable — see **Shared software
layout** below.

---

## Application example — MOOSE (source build + Lmod module)

[MOOSE](https://mooseframework.inl.gov) is INL's multiphysics finite-element framework, built on
PETSc + libMesh + WASP. Unlike PFLOTRAN you don't hand-pin PETSc — MOOSE's own scripts build the
exact dependency versions it needs.

### Route 1 — Conda (fastest; INL's preferred)

```bash
conda config --add channels https://conda.software.inl.gov/public
conda create -n moose moose-dev=2025.06.13=mpich     # use the current version on the conda page
conda activate moose

mkdir -p ~/projects && cd ~/projects
git clone https://github.com/idaholab/moose.git
cd moose && git checkout master
cd test && make -j 8 && ./run_tests -j 8
```

Pre-built and reproducible, but it ships **mpich** (not your OpenMPI), and INL notes these packages
aren't meant for benchmark/performance work. Under Slurm, launch with `srun --mpi=pmi2` and put
`conda activate moose` inside the job script. Never use sudo with Conda.

### Route 2 — Source build against your OpenMPI (tuned; best Slurm integration)

**1. Install the build prerequisites** (the pieces a fresh Ubuntu is missing):

```bash
sudo apt install -y flex bison libtool autoconf automake m4 libtirpc-dev
# Python deps for the test harness, into the python that runs run_tests
# (system python may need --break-system-packages, or use your Miniforge):
pip install numpy pandas scipy pyyaml jinja2
```

**2. Set your MPI and build the dependency chain:**

```bash
spack load openmpi
export CC=mpicc CXX=mpicxx FC=mpif90 F90=mpif90 F77=mpif77
export MOOSE_JOBS=8

cd /opt/sw
git clone https://github.com/idaholab/moose.git
cd moose && git checkout master

./scripts/update_and_rebuild_petsc.sh      # PETSc (incl. hypre, MUMPS, SuperLU_DIST…) against your OpenMPI
./scripts/update_and_rebuild_libmesh.sh
./scripts/update_and_rebuild_wasp.sh
```

If the WASP step dies on a `git submodule` **HTTP 403** from `code.ornl.gov` (its test-only
submodules occasionally throttle), retry — or skip the test-only ones, since only TriBITS is needed
to build:

```bash
cd /opt/sw/moose/framework/contrib/wasp
git config submodule.testframework.update none
git config submodule.googletest.update none
git submodule update --init TriBITS
cd /opt/sw/moose && ./scripts/update_and_rebuild_wasp.sh
```

**3. Build and test:**

```bash
cd /opt/sw/moose/test
make -j 8
export PMIX_MCA_psec=native
srun --mpi=pmix -n 4 ./moose_test-opt -i tests/kernels/simple_diffusion/simple_diffusion.i
```

`moose_test-opt` is the framework's test app. For real multiphysics work, build the bundled
**modules** app (all physics in one executable):

```bash
cd /opt/sw/moose/modules/combined && make -j 8        # produces combined-opt
```

### Expose it as an Lmod module

```bash
sudo mkdir -p /opt/modulefiles/moose
sudo tee /opt/modulefiles/moose/dev.lua > /dev/null << 'EOF'
-- -*- lua -*-
whatis("Name: MOOSE")
whatis("Description: Multiphysics finite-element framework (built against OpenMPI 5.0.10)")

help([[ MOOSE modules app, built from source against Spack OpenMPI 5.0.10.
Run: srun --mpi=pmix -n N combined-opt -i <input>.i ]])

-- adjust if you built elsewhere
local moose_bin = "/opt/sw/moose/modules/combined"

depends_on("openmpi")
prepend_path("PATH", moose_bin)
setenv("PMIX_MCA_psec", "native")
EOF
```

(`module use /opt/modulefiles` is already set from the PFLOTRAN step.) Then:

```bash
module load moose/dev
srun --mpi=pmix -n 4 combined-opt -i your_model.i
```

**Team access:** this builds into `/opt/sw` with its modulefile in `/opt/modulefiles`, so the team
can `module load moose/dev` — see **Shared software layout** below.

---

## Application example — DOLFINx + Reaktoro (shared conda-env modules)

Some scientific codes ship primarily as **conda-forge Python packages** rather than things you compile
against your MPI. [DOLFINx](https://fenicsproject.org) (FEniCSx finite elements) and
[Reaktoro](https://reaktoro.org) (chemical reaction modeling) are two such cases. The shared-install
pattern here is a **conda environment per package under `/opt/sw`, exposed as an Lmod module** — so the
team gets them without each person managing conda.

Install them in **separate** environments (cleaner isolation, independent updates); use one combined
env only if you need to `import dolfinx` and `import reaktoro` in the same script.

### Create the two envs

```bash
# DOLFINx — needs MPI (conda's MPICH; see the MPI note below)
conda create -p /opt/sw/conda/envs/dolfinx -c conda-forge -y \
  fenics-dolfinx mpich gmsh pyvista scipy matplotlib

# Reaktoro — serial chemistry, no MPI
conda create -p /opt/sw/conda/envs/reaktoro -c conda-forge -y \
  reaktoro numpy scipy matplotlib

chmod -R o+rX /opt/sw/conda        # make both team-readable
```

(Resolved here as DOLFINx 0.10.0 and Reaktoro 2.13.0.)

### Modulefiles (mutually exclusive)

Each module prepends its env's `bin` to `PATH`; `family("pyenv")` makes them mutually exclusive, so
loading one auto-unloads the other and two conda `python`s never collide on `PATH`.

```bash
sudo mkdir -p /opt/modulefiles/dolfinx /opt/modulefiles/reaktoro

sudo tee /opt/modulefiles/dolfinx/2026.lua > /dev/null << 'EOF'
-- -*- lua -*-
whatis("Name: DOLFINx (FEniCSx)")
whatis("Description: Shared conda env — fenics-dolfinx (Python/MPI finite elements)")
family("pyenv")          -- mutually exclusive with other pyenv modules (e.g. reaktoro)
help([[ DOLFINx via a shared conda env.  python -c "import dolfinx"
  parallel:  mpirun -n N python your_script.py ]])
local root = "/opt/sw/conda/envs/dolfinx"
prepend_path("PATH",            pathJoin(root, "bin"))
prepend_path("LD_LIBRARY_PATH", pathJoin(root, "lib"))
setenv("CONDA_PREFIX", root)
EOF

sudo tee /opt/modulefiles/reaktoro/2026.lua > /dev/null << 'EOF'
-- -*- lua -*-
whatis("Name: Reaktoro")
whatis("Description: Shared conda env — reaktoro (chemical reaction modeling, Python)")
family("pyenv")          -- mutually exclusive with other pyenv modules (e.g. dolfinx)
help([[ Reaktoro via a shared conda env.  python -c "import reaktoro" ]])
local root = "/opt/sw/conda/envs/reaktoro"
prepend_path("PATH",            pathJoin(root, "bin"))
prepend_path("LD_LIBRARY_PATH", pathJoin(root, "lib"))
setenv("CONDA_PREFIX", root)
EOF
```

### Use

```bash
module load dolfinx/2026   &&  cd ~/runs/job  &&  mpirun -n 4 python model.py
module load reaktoro/2026  &&  cd ~/runs/job  &&  python chemistry.py
```

Loading `reaktoro` while `dolfinx` is active prints a clean *"Lmod is automatically replacing
dolfinx/2026 with reaktoro/2026"* swap rather than colliding.

### MPI note

The DOLFINx env uses **conda's own MPICH**, not your system OpenMPI 5.0.10 — it's self-contained
(its own `mpi4py`/`petsc4py`). MPICH speaks PMI/PMI2, so launch parallel runs with the env's own
`mpirun -n N python …` (or `srun --mpi=pmi2`), **not** `srun --mpi=pmix` (that's your OpenMPI's
interface). On a single node `mpirun` is bulletproof. If you later need DOLFINx on your tuned system
OpenMPI (e.g. scaling across nodes), build it via Spack instead:
`spack install py-fenics-dolfinx+petsc4py+slepc4py`.

### When a script needs BOTH (one combined env)

The separate envs above are mutually exclusive (`family("pyenv")`) — loading one auto-unloads the
other, so a single `python` process can't `import dolfinx` **and** `import reaktoro`. If you have a
coupled script that uses both (e.g. a reactive-transport model where DOLFINx does the FE transport and
Reaktoro does the per-cell equilibrium in the same loop), make **one combined env** instead:

```bash
conda create -p /opt/sw/conda/envs/dolfinx-reaktoro -c conda-forge -y \
  fenics-dolfinx mpich reaktoro petsc4py mpi4py \
  gmsh pyvista scipy matplotlib numpy

chmod -R o+rX /opt/sw/conda/envs/dolfinx-reaktoro
```

conda-forge has to find one set of versions satisfying both packages (they share `petsc`/`mpi`); the
libmamba solver (default on recent conda) handles this. If it conflicts or drags, pin a DOLFINx
version. Expose it as one module (still `family("pyenv")`, so it swaps cleanly with the single-package
ones):

```bash
sudo mkdir -p /opt/modulefiles/dolfinx-reaktoro

sudo tee /opt/modulefiles/dolfinx-reaktoro/2026.lua > /dev/null << 'EOF'
-- -*- lua -*-
whatis("Name: DOLFINx + Reaktoro (combined)")
whatis("Description: Shared conda env with both fenics-dolfinx and reaktoro")
family("pyenv")          -- swaps with dolfinx/reaktoro single-package modules
help([[ Combined env: import dolfinx AND import reaktoro in one script.
  parallel:  mpirun -n N python your_script.py ]])
local root = "/opt/sw/conda/envs/dolfinx-reaktoro"
prepend_path("PATH",            pathJoin(root, "bin"))
prepend_path("LD_LIBRARY_PATH", pathJoin(root, "lib"))
setenv("CONDA_PREFIX", root)
EOF
```

Usage (still conda's MPICH, so the env's own `mpirun` or `srun --mpi=pmi2`, **not** `--mpi=pmix`):

```bash
module load dolfinx-reaktoro/2026
mkdir -p ~/runs/job && cd ~/runs/job
OMP_NUM_THREADS=1 mpirun -n 38 python your_coupled_script.py
```

For heavy per-cell Reaktoro work, set `OMP_NUM_THREADS=1` (and the matching `OPENBLAS_/MKL_` vars) so
each MPI rank stays single-threaded and you don't oversubscribe the 48 cores. Don't try to combine the
two *separate* envs via `PYTHONPATH` — each ships its own compiled MPI/PETSc and mixing them segfaults;
the combined env is the supported way.

---

## Application example — OpenFOAM (source build against your MPI)

OpenFOAM is the open-source CFD toolbox. There are **two independent distributions** — `openfoam.com`
(ESI-OpenCFD, dated versions like **v2506**) and `openfoam.org` (Foundation, versions like **v13**).
They are *not* fully case/solver-compatible; pick one and stick to it. This builds **openfoam.com
v2506 from source** into `/opt/sw`, linked against your **Spack OpenMPI 5.0.10** (same MPI as PFLOTRAN
and MOOSE — one launcher, one module ecosystem) rather than OpenFOAM's bundled OpenMPI.

> The `openfoam.com` apt package (`wget -qO- https://dl.openfoam.com/add-debian-repo.sh | sudo bash`
> then `apt install openfoam2506-dev`) is far quicker and installs system-wide for everyone — but it
> uses its **own** OpenMPI, not your Spack one. Use it if you don't need OpenFOAM to share your tuned
> MPI; use the source build below if you do.

### 1. Prerequisites (apt)

```bash
sudo apt update
sudo apt install -y build-essential autoconf autotools-dev cmake gawk gnuplot \
  flex libfl-dev bison zlib1g-dev libboost-system-dev libboost-thread-dev \
  libreadline-dev libncurses-dev libxt-dev libscotch-dev libptscotch-dev \
  libfftw3-dev libcgal-dev libgmp-dev libmpfr-dev m4
```

### 2. Get the source (OpenFOAM moved to GitLab)

```bash
mkdir -p /opt/sw/openfoam && cd /opt/sw/openfoam

# confirm the exact tag name first (they use OpenFOAM-vYYMM for core, vYYMM for ThirdParty)
git ls-remote --tags https://gitlab.com/openfoam/core/openfoam.git | grep v2506

git clone --branch OpenFOAM-v2506 --depth 1 \
  https://gitlab.com/openfoam/core/openfoam.git OpenFOAM-v2506
git clone --branch v2506 --depth 1 \
  https://gitlab.com/openfoam/core/ThirdParty-common.git ThirdParty-v2506
```

The ThirdParty repo is `ThirdParty-common.git` (not `thirdparty.git`), and it **must** be cloned to a
directory named `ThirdParty-v2506` — OpenFOAM's bashrc looks for `ThirdParty-$WM_PROJECT_VERSION`
beside the core dir. A wrong repo name silently prompts for a GitLab username/password (that's what a
missing-repo 404 looks like over HTTPS) — it is *not* an auth problem. Several releases share one
ThirdParty snapshot (v2406/v2412/v2506 point at the same commit), which is expected.

### 3. Point OpenFOAM at your Spack OpenMPI

`WM_MPLIB=SYSTEMMPI` tells OpenFOAM to use the already-loaded MPI instead of compiling its own:

```bash
module purge
module load openmpi/5.0.10
which mpicc mpicxx                  # must resolve into /opt/spack/...

cd /opt/sw/openfoam/OpenFOAM-v2506
sed -i 's/^export WM_MPLIB=SYSTEMOPENMPI/export WM_MPLIB=SYSTEMMPI/' etc/bashrc

# SYSTEMMPI needs these three vars (derived from mpicc's location):
export MPI_ROOT="$(dirname "$(dirname "$(which mpicc)")")"
export MPI_ARCH_FLAGS="-DOMPI_SKIP_MPICXX"
export MPI_ARCH_INC="-I$MPI_ROOT/include"
export MPI_ARCH_LIBS="-L$MPI_ROOT/lib -lmpi"

source /opt/sw/openfoam/OpenFOAM-v2506/etc/bashrc
foamSystemCheck                     # expect: System check: PASS
echo "$WM_MPLIB / $FOAM_MPI"         # expect: SYSTEMMPI / sys-mpi
```

> **Decomposition library (scotch) — do this BEFORE the main build.** OpenFOAM partitions parallel
> meshes with **scotch**, but its default config looks for a ThirdParty-built `scotch_6.1.0` that the
> `ThirdParty-common` repo does **not** ship (that repo has build *scripts*, not source tarballs). So
> out of the box you get only a *dummy* scotch stub and **all parallel decomposition fails** at
> runtime (`Attempted to use <scotch> without the scotchDecomp library loaded`). The serial solver
> works regardless, which makes this easy to miss until the first parallel run.
>
> Setting `export SCOTCH_TYPE=system` in your shell does **not** fix it — sourcing `etc/bashrc`
> re-reads `etc/config.sh/scotch`, which overwrites your shell value back to the ThirdParty default.
> You must edit the config file itself, and bridge the apt header location (Ubuntu puts it in a
> `scotch/` subdir that OpenFOAM doesn't probe):
>
> ```bash
> # point OpenFOAM's scotch config at the apt install (libscotch-dev / libptscotch-dev)
> cd /opt/sw/openfoam/OpenFOAM-v2506
> cp etc/config.sh/scotch etc/config.sh/scotch.bak
> sed -i 's|^export SCOTCH_TYPE=.*|export SCOTCH_TYPE=system|'      etc/config.sh/scotch
> sed -i 's|^export SCOTCH_ARCH_PATH=.*|export SCOTCH_ARCH_PATH=/usr|' etc/config.sh/scotch
>
> # apt puts the header in /usr/include/scotch/ but OpenFOAM probes /usr/include/ — bridge it:
> sudo ln -sf /usr/include/scotch/scotch.h   /usr/include/scotch.h
> sudo ln -sf /usr/include/scotch/ptscotch.h /usr/include/ptscotch.h
>
> source /opt/sw/openfoam/OpenFOAM-v2506/etc/bashrc
> echo "$SCOTCH_ARCH_PATH"            # MUST now print /usr, not a ThirdParty path
> ```
>
> The other optional libs (FFTW/CGAL/metis/kahip) are also ThirdParty-default and will be skipped the
> same way; they aren't needed for standard incompressible/compressible solvers, so leave them unless
> a specific solver requires one — then apply the same `config.sh/<lib>` edit. (Alternatively, build
> scotch via Spack — `spack install scotch` — and point `SCOTCH_ARCH_PATH` at its prefix, consistent
> with how OpenMPI is managed; either works.)

### 4. Build (large — an hour-plus on 48 cores; resumable)

```bash
export WM_NCOMPPROCS=48
cd "$WM_PROJECT_DIR"
./Allwmake -s -l -j 48 2>&1 | tee /opt/sw/openfoam/build-v2506.log
```

`-s` quiets, `-l` logs, `-j 48` parallelizes. If it dies, fix the cause and re-run `./Allwmake` — it
skips what's already built. Verify a solver appeared:

```bash
which simpleFoam icoFoam blockMesh   # → /opt/sw/openfoam/OpenFOAM-v2506/platforms/.../bin
```

If you set up system scotch *after* an initial full build (or want to be sure the real wrapper got
built rather than the dummy stub), rebuild just the decomposition libraries — it's quick:

```bash
src/parallel/decompose/Allwmake 2>&1 | tee /opt/sw/openfoam/rebuild-decompose.log
# the log should show 'scotch (int) - /usr' and 'wmake scotchDecomp' (NOT 'skip scotch (no header)')

# confirm the REAL libraries exist (serial in lib/, parallel in lib/sys-mpi/):
ls -l "$FOAM_LIBBIN/libscotchDecomp.so"            # must exist OUTSIDE dummy/
ls -l "$FOAM_LIBBIN/sys-mpi/libptscotchDecomp.so"  # parallel scotch
ldd "$FOAM_LIBBIN/libscotchDecomp.so" | grep -i scotch   # → /usr/lib/.../libscotch.so.7.0
```

### 5. Modulefile

Unlike the other apps, OpenFOAM sets ~40 env vars via its own `etc/bashrc`, so the module sources that
(after loading your MPI) rather than hand-setting `PATH`. **One extra step matters here:** a SYSTEMMPI
build records no rpath to your Spack MPI, so if the distro also has an apt OpenMPI installed (it often
arrives as a dependency of `libptscotch-dev`), `simpleFoam` can bind the apt `libmpi.so.40` from
`/usr/lib` instead of your Spack one. Even when the apt OpenMPI is the *same version* (e.g. both
5.0.10), you want OpenFOAM on the Spack build so it matches PFLOTRAN/MOOSE and `srun --mpi=pmix`. The
module forces this by prepending the Spack MPI lib to `LD_LIBRARY_PATH`:

```bash
sudo mkdir -p /opt/modulefiles/openfoam

sudo tee /opt/modulefiles/openfoam/v2506.lua > /dev/null << 'EOF'
-- -*- lua -*-
whatis("Name: OpenFOAM v2506 (openfoam.com), built against Spack OpenMPI 5.0.10")
help([[ OpenFOAM CFD toolbox, linked to the Spack OpenMPI 5.0.10 module.
  Run from your own dir:  blockMesh; decomposePar; mpirun -n N simpleFoam -parallel
  (or under Slurm:        srun --mpi=pmix simpleFoam -parallel) ]])

-- Load the same MPI it was built against (prepends Spack MPI to PATH/LD_LIBRARY_PATH).
depends_on("openmpi/5.0.10")

local foam = "/opt/sw/openfoam/OpenFOAM-v2506"
setenv("FOAM_INST_DIR", "/opt/sw/openfoam")
setenv("MPI_ARCH_FLAGS", "-DOMPI_SKIP_MPICXX")   -- SYSTEMMPI var bashrc expects

-- Source OpenFOAM's environment (exports FOAM_*, WM_*, PATH, LD_LIBRARY_PATH):
execute{cmd="source " .. foam .. "/etc/bashrc", modeA={"load"}}

-- FORCE the Spack OpenMPI lib ahead of any apt libmpi, so simpleFoam always binds
-- the Spack one (matching srun --mpi=pmix). Derive it from the loaded module rather
-- than hard-coding the Spack hash, so it survives an OpenMPI rebuild:
local mpicc = capture("which mpicc 2>/dev/null"):gsub("%s+$", "")
if mpicc ~= "" then
  local mpi_lib = mpicc:gsub("/bin/mpicc$", "/lib")
  prepend_path("LD_LIBRARY_PATH", mpi_lib)
end

setenv("PMIX_MCA_psec", "native")        -- silence harmless PMIx/munge warning
EOF
```

> `execute{cmd="source …bashrc"}` runs OpenFOAM's setup at module-load time, and `capture("which
> mpicc")` reads the loaded module's MPI location (no hard-coded Spack hash). If your Lmod build is
> strict about `execute`/`capture`, hard-code the lib path instead — find it with
> `dirname $(dirname $(which mpicc))`/lib while `openmpi/5.0.10` is loaded — and `prepend_path` that
> literal. Test with `module load openfoam/v2506 && ldd $(which simpleFoam) | grep -i mpi` (expect the
> Spack path) either way.

### 6. Use (team)

```bash
module load openfoam/v2506
ldd "$(which simpleFoam)" | grep -i mpi    # sanity: → /opt/spack/.../openmpi-5.0.10-.../lib
mkdir -p ~/runs/cavity && cd ~/runs/cavity
cp -r "$FOAM_TUTORIALS/incompressible/icoFoam/cavity/cavity" .
cd cavity
blockMesh
icoFoam                                   # serial
# parallel: edit system/decomposeParDict, then decompose, run, reconstruct.
# The cavity tutorial defaults to method 'hierarchical' with coeffs (3 3 1) = 9 domains;
# numberOfSubdomains must match the method's coeffs, OR use scotch (no coeffs needed):
cat > system/decomposeParDict << 'EOF'
FoamFile { version 2.0; format ascii; class dictionary; object decomposeParDict; }
numberOfSubdomains 4;
method scotch;
EOF
decomposePar -force                 # -force overwrites any partial decomposition
mpirun -n 4 icoFoam -parallel       # → creates/uses processor0..3
reconstructPar                      # merge processor results back
```

Because OpenFOAM was built against your Spack OpenMPI, parallel runs use the **same** launcher as your
other codes: `mpirun -n N <solver> -parallel`, or under Slurm `srun --mpi=pmix <solver> -parallel`.
As with the other apps, run from your **own** directory — `/opt/sw` is read-only and OpenFOAM writes
case data (mesh, time directories) into the working dir.

---

## Application example — PhreeqcRM (a library to link, not a program to run)

[PhreeqcRM](https://github.com/usgs-coupled/phreeqcrm) is the USGS reaction module for
reactive-transport simulators — the PHREEQC geochemistry engine packaged as a C/C++/Fortran library
you **link into your own transport solver**, not a standalone executable. This example builds it as a
**serial/OpenMP C/C++ shared library** for the common coupling pattern where *your solver* does the
MPI and calls PhreeqcRM per-rank on each rank's local cells. (PhreeqcRM can also do its own internal
MPI partitioning; if you need that, build with the MPI compilers and the version's MPI CMake option
instead — see the note at the end.)

### 1. Clone from GitHub and pick a tagged release

The official USGS download page lags the GitHub dev repo; GitHub has newer tags. Clone and check out
the newest version tag:

```bash
mkdir -p /opt/sw/phreeqcrm && cd /opt/sw/phreeqcrm
git clone https://github.com/usgs-coupled/phreeqcrm.git src
cd src
git tag | tail              # newest tag, e.g. v3.9.0
git checkout v3.9.0
git submodule update --init --recursive   # no-op if self-contained (3.9.0 is)
```

### 2. Configure (plain compilers — no MPI for the per-rank pattern)

With PhreeqcRM's own MPI off, it has no MPI calls to link, so build it with plain `gcc`/`g++` — it
then has **no OpenMPI dependency at all** (your solver brings the MPI). OpenMP is auto-detected and
left on for optional per-rank threading.

```bash
module purge                # no openmpi module needed for this build
SRC=/opt/sw/phreeqcrm/src
PREFIX=/opt/sw/phreeqcrm/3.9.0

cmake -S "$SRC" -B "$SRC/_build" \
  -DCMAKE_INSTALL_PREFIX="$PREFIX" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_C_COMPILER=gcc \
  -DCMAKE_CXX_COMPILER=g++ \
  -DBUILD_SHARED_LIBS=ON \
  -DCMAKE_C_FLAGS="-O3 -march=znver4" \
  -DCMAKE_CXX_FLAGS="-O3 -march=znver4"
```

A clean configure shows **no** "Manually-specified variables were not used" warning. (If you pass MPI
or Fortran flags the version doesn't recognize, that warning is how it tells you — drop the flags or
find the right names with `grep -rin "mpi\|fortran" "$SRC/CMakeLists.txt" | grep -i option`.)

### 3. Build and install

```bash
cmake --build "$SRC/_build" --config Release -j 48
cmake --install "$SRC/_build" --config Release
```

Confirm the layout (the names matter — see the gotcha below):

```bash
find "$PREFIX" -name 'libPhreeqcRM*'          # → lib/libPhreeqcRM.so  (capital P,R,M!)
find "$PREFIX" -name 'PhreeqcRM.h'            # → include/PhreeqcRM.h
find "$PREFIX" -name '*.dat' | head           # → share/doc/PhreeqcRM/database/phreeqc.dat, ...
ldd "$PREFIX/lib/libPhreeqcRM.so" | grep -i mpi || echo "no MPI deps (correct)"
```

> **The library is `libPhreeqcRM.so` — capitalized — so the link flag is `-lPhreeqcRM`, not
> `-lphreeqcrm`.** The bundled `phreeqcrm.pc` confirms it (`Libs: -lPhreeqcRM`). The databases install
> under `share/doc/PhreeqcRM/database/` (phreeqc.dat, pitzer.dat, llnl.dat, minteq.v4.dat, …).

### 4. Modulefile (a library module — sets compile/link discovery vars)

No `depends_on("openmpi")` — this serial build is standalone. The module sets the variables a
downstream compile/link needs (`CPATH`, `LIBRARY_PATH`, `LD_LIBRARY_PATH`, `CMAKE_PREFIX_PATH`,
`PKG_CONFIG_PATH`) plus a convenience `PHREEQCRM_DATABASE`:

```bash
sudo mkdir -p /opt/modulefiles/phreeqcrm

sudo tee /opt/modulefiles/phreeqcrm/3.9.0.lua > /dev/null << 'EOF'
-- -*- lua -*-
whatis("Name: PhreeqcRM 3.9.0 (USGS, GitHub) — serial/OpenMP C/C++ library")
help([[ PhreeqcRM reaction-module library (C/C++), serial (no internal MPI).
  Link with -lPhreeqcRM (capital P,R,M). Header: PhreeqcRM.h.
  Databases in $PHREEQCRM_DATABASE (phreeqc.dat, pitzer.dat, llnl.dat, ...).
  Coupling pattern: your solver does MPI; PhreeqcRM runs serial per rank.
  Build flags via pkg-config:  pkg-config --cflags --libs phreeqcrm ]])
local root = "/opt/sw/phreeqcrm/3.9.0"
setenv("PHREEQCRM_DIR", root)
setenv("PHREEQCRM_DATABASE", pathJoin(root, "share/doc/PhreeqcRM/database"))
prepend_path("CMAKE_PREFIX_PATH", root)
prepend_path("CPATH",            pathJoin(root, "include"))
prepend_path("LIBRARY_PATH",     pathJoin(root, "lib"))
prepend_path("LD_LIBRARY_PATH",  pathJoin(root, "lib"))
prepend_path("PKG_CONFIG_PATH",  pathJoin(root, "lib/pkgconfig"))
EOF
```

### 5. Verify with a link-and-run smoke test

Because the bundled examples split `main()` (in `Tests/main.cpp`) from the worker routines, a single
example file won't link alone. A 6-line standalone program is the cleanest proof the module works —
it tests header discovery, linking, runtime loading, and that the library initializes and reads a
database:

```bash
module purge && module load phreeqcrm/3.9.0
cd /tmp
cat > rm_smoke.cpp << 'CPP'
#include "PhreeqcRM.h"
#include <iostream>
int main() {
    PhreeqcRM rm(4, 1);                          // 4 cells, 1 thread, no MPI
    IRM_RESULT s = rm.LoadDatabase("phreeqc.dat");
    std::cout << "LoadDatabase result: " << s << " (0=OK)\n";
    return (s == IRM_OK) ? 0 : 1;
}
CPP
g++ -O3 -fopenmp rm_smoke.cpp -lPhreeqcRM -o rm_smoke   # CPATH/LIBRARY_PATH from the module
cp "$PHREEQCRM_DATABASE/phreeqc.dat" .
./rm_smoke                                              # → LoadDatabase result: 0 (0=OK)
```

`result: 0` and exit code 0 means PhreeqcRM is ready. Note no `-I`/`-L` flags were needed — the
module's `CPATH`/`LIBRARY_PATH` supply them; in a Makefile you'd typically use
`pkg-config --cflags --libs phreeqcrm` or add `-I$PHREEQCRM_DIR/include -L$PHREEQCRM_DIR/lib`
explicitly.

**Running a real bundled example.** To exercise a full reactive-transport calculation, compile one of
the `Tests/` example *functions* with your own one-line `main` (their `main.cpp` is a multi-test
dispatcher that won't link standalone, and globbing `Tests/*.cpp` collides on multiple `main`s — so
wrap just the one function you want):

```bash
module purge && module load phreeqcrm/3.9.0
cd /tmp
cat > run_simpleadvect.cpp << 'CPP'
void SimpleAdvect_cpp();                       // defined in SimpleAdvect_cpp.cpp
int main() { SimpleAdvect_cpp(); return 0; }
CPP
g++ -O3 -fopenmp run_simpleadvect.cpp \
  /opt/sw/phreeqcrm/src/Tests/SimpleAdvect_cpp.cpp \
  -lPhreeqcRM -o simpleadvect
cp "$PHREEQCRM_DATABASE/phreeqc.dat" .          # example reads files by relative name
cp /opt/sw/phreeqcrm/src/Tests/advect.pqi .
./simpleadvect
```

A correct run prints a 10-day transport/reaction loop (`Beginning transport calculation` /
`Beginning reaction calculation` per step, with OpenMP `Cells shifted between threads` and load-balance
lines) and exits cleanly — a genuine coupled geochemical-transport simulation, not just a link test.
The same pattern works for the other example functions (`Advect_cpp`, `Species_cpp`, `Gas_cpp`, …):
declare the one you want and give it a `main`.

> **Need PhreeqcRM's own MPI** (one instance partitioning cells across ranks) instead of the per-rank
> pattern? Rebuild against your Spack OpenMPI: `module load openmpi/5.0.10`, configure with
> `-DCMAKE_CXX_COMPILER=mpicxx -DCMAKE_C_COMPILER=mpicc` plus the version's MPI option (find it via the
> `grep` in step 2), and add `depends_on("openmpi/5.0.10")` to the modulefile. Then check
> `ldd libPhreeqcRM.so | grep mpi` resolves into `/opt/spack/…` as the other MPI apps do.

---

## Application: dfnWorks (discrete fracture networks → PFLOTRAN)

dfnWorks (LANL) generates 3D discrete fracture networks, meshes them with **LaGriT**, solves flow with
**PFLOTRAN**, and tracks transport with **DFNTrans** — driven by the **pydfnworks** Python package. It
reuses the PFLOTRAN and PETSc already built in `/opt/sw` (it just needs their paths), so you only build
the new pieces: LaGriT, DFNGen, DFNTrans, and the Python package.

**The whole story here is GCC 15 strictness.** dfnWorks' components are older C/C++/Fortran, and
Ubuntu 26.04's GCC 15 turns what used to be warnings into hard errors. Each component builds fine once
you relax the right diagnostics. The recipe below is the same one that works for most legacy scientific
codes on this OS — keep it handy.

### 1. Prerequisites (already present)

`cmake build-essential gfortran git` (from Step 1), plus the existing `/opt/sw/petsc` and
`/opt/sw/pflotran`. Nothing new to install system-wide.

### 2. Build LaGriT (the mesher) — the hardest component

```bash
mkdir -p /opt/sw/dfnworks && cd /opt/sw/dfnworks
git clone https://github.com/lanl/LaGriT.git
cd LaGriT && mkdir build && cd build

cmake .. -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_C_FLAGS="-w -fcommon -std=gnu17 -Wno-error=implicit-int -Wno-error=implicit-function-declaration -Wno-error=incompatible-pointer-types -Wno-error=int-conversion -Wno-error=return-mismatch" \
  -DCMAKE_Fortran_FLAGS="-w -fallow-argument-mismatch -fallow-invalid-boz -std=legacy"

make -j8
echo "finish" | ./lagrit          # smoke test: prints banner, "LaGriT successfully completed"
```

> **Why each flag.** `-std=gnu17` is the critical one: GCC 15 defaults to C23, where an empty `()` in a
> declaration means "no arguments", breaking K&R-style code that calls those functions with arguments
> (you'll see *"too many arguments to function"*). `gnu17` restores the old meaning. The `-Wno-error=…`
> flags downgrade GCC-14/15 hard errors (implicit-int, incompatible-pointer-types, int-conversion,
> return-mismatch) back to warnings. `-fcommon` allows old multiple-definition behavior. On the Fortran
> side, `-std=legacy -fallow-argument-mismatch` does the equivalent. LaGriT progresses through three
> distinct error classes as you add these; the full set above gets it to 100%.

### 3. Clone dfnWorks; build DFNGen and DFNTrans

```bash
cd /opt/sw/dfnworks
git clone https://github.com/lanl/dfnWorks.git
cd dfnWorks

# DFNGen — C++ fracture generator (Makefile honours CXXFLAGS override)
cd DFNGen
make CXXFLAGS="-std=gnu++17 -O3 -lm -w -fpermissive"
ls -l DFNGen                       # → executable
cd ..

# DFNTrans — C particle-tracking transport
cd DFNTrans
make CFLAGS="-lm -O3 -w -std=gnu17 -fcommon -Wno-error=implicit-int -Wno-error=implicit-function-declaration -Wno-error=incompatible-pointer-types -Wno-error=int-conversion -Wno-error=return-mismatch"
ls -l DFNTrans                     # → executable
cd ..
```

> `-fpermissive -std=gnu++17` is the C++ analogue of the C relaxations — it downgrades C++ conformance
> errors and avoids C++20/23 defaults that break the older code. DFNGen and DFNTrans each build in one
> pass with these.

### 4. pydfnworks (Python package) in a shared conda env

```bash
conda create -p /opt/sw/conda/envs/dfnworks -c conda-forge -y \
  python=3.11 numpy h5py scipy matplotlib networkx mplstereonet fpdf2 pyvista vtk

conda activate /opt/sw/conda/envs/dfnworks
cd /opt/sw/dfnworks/dfnWorks/pydfnworks
pip install .                      # NON-editable — copies into site-packages
cd /tmp && python -c "import pydfnworks; print('OK')"   # must work from OUTSIDE the source dir
```

> **Use `pip install .`, not `pip install -e .`.** The editable install can appear to work only because
> you're sitting in the source directory (Python finds the local `pydfnworks/` subfolder), then fails
> from anywhere else — which breaks Slurm jobs that run from `~/runs/...`. The test that matters is
> importing from `/tmp`. A plain `pip install .` copies it into the env's site-packages so it imports
> from any directory.

### 5. Modulefile

```bash
sudo mkdir -p /opt/modulefiles/dfnworks
sudo tee /opt/modulefiles/dfnworks/2.7.lua > /dev/null << 'EOF'
-- -*- lua -*-
whatis("Name: dfnWorks 2.7 — DFN suite (LaGriT + DFNGen + DFNTrans + pydfnworks), coupled to PFLOTRAN")
help([[ Run as a Slurm job (see dfnworks.sh). Activate the conda env for pydfnworks:
  source /opt/miniforge3/etc/profile.d/conda.sh; conda activate /opt/sw/conda/envs/dfnworks
  NOTE: use ncpu=1 in driver.py for small nets — the parallel LaGriT merge can hang. ]])
family("pyenv")
depends_on("openmpi/5.0.10")
local root = "/opt/sw/dfnworks"
local env  = "/opt/sw/conda/envs/dfnworks"
setenv("dfnworks_PATH", root .. "/dfnWorks/")
setenv("PETSC_DIR", "/opt/sw/petsc")
setenv("PETSC_ARCH", "arch-linux-c-opt")
setenv("PFLOTRAN_EXE", "/opt/sw/pflotran/src/pflotran/pflotran")
setenv("LAGRIT_EXE", root .. "/LaGriT/build/lagrit")
setenv("DFNGEN_EXE", root .. "/dfnWorks/DFNGen/DFNGen")
setenv("DFNTRANS_EXE", root .. "/dfnWorks/DFNTrans/DFNTrans")
setenv("PYTHON_EXE", env .. "/bin/python")
prepend_path("PATH", env .. "/bin")
prepend_path("PATH", root .. "/LaGriT/build")
prepend_path("PATH", root .. "/dfnWorks/DFNGen")
prepend_path("PATH", root .. "/dfnWorks/DFNTrans")
prepend_path("LD_LIBRARY_PATH", env .. "/lib")
EOF

chmod -R o+rX /opt/sw/dfnworks /opt/sw/conda/envs/dfnworks
module purge && module --ignore_cache load dfnworks/2.7    # --ignore_cache picks up the new file
module list                                                # shows dfnworks/2.7 + openmpi/5.0.10
```

### 6. Verify end-to-end (the real test)

```bash
mkdir -p ~/runs && cd ~/runs
cp -r /opt/sw/dfnworks/dfnWorks/examples/4_user_rects .
cd 4_user_rects
sed -i 's/ncpu=4/ncpu=1/' driver.py     # serial merge (see caveat below)
# submit via Slurm (see the dfnworks.sh template), then watch:
sbatch dfnworks.sh && tail -f dfnworks-*.out
```

A successful run shows: DFNGen network generation → LaGriT meshing + merge → **`mpirun -np 1
.../pflotran -pflotranin dfn_explicit.in` → "Running PFLOTRAN Complete"** → DFNTrans → VTK output. That
PFLOTRAN line is the proof dfnWorks is driving the shared `/opt/sw` PFLOTRAN.

> **Two operational caveats, both important:**
> 1. **Use `ncpu=1` for small/moderate networks.** The *parallel* LaGriT merge (`ncpu>1`) can spin in a
>    busy-loop and hang on small problems in this build (you'll see `lagrit … merge_part_N` processes
>    pegged at ~96% CPU forever). Serial merge finishes in seconds and is reliable. Only raise `ncpu`
>    for genuinely large networks, and verify it completes. (If large-network parallel meshing is ever
>    needed, try rebuilding LaGriT at `-O2` instead of `-O3` — aggressive optimization can change loop
>    behaviour in the old Fortran.)
> 2. **Run through Slurm, not interactively.** dfnWorks' pipeline wants real cores, and interactive CPU
>    is capped per user (see the interactive-limits section). In the batch script, **activate the conda
>    env** (`conda activate /opt/sw/conda/envs/dfnworks`) — don't just call the env's python binary, or
>    `import pydfnworks` fails. And do **not** wrap `python driver.py` in `srun`: dfnWorks calls
>    `mpirun` internally to launch PFLOTRAN.

---

## Application: LAMMPS (CPU and GPU, split modules)

LAMMPS is installed as **two modules from one source tree**, so users get the same physics on CPU or
GPU and pick the build that fits the job:

| Module | Prefix | Backends | Packages |
|---|---|---|---|
| `lammps/stable` | `/opt/sw/lammps` | MPI + OpenMP (KOKKOS host) | ~68 (`most.cmake`, no GPU) |
| `lammps-gpu/stable` | `/opt/sw/lammps-gpu` | GPU package + KOKKOS/CUDA, also CPU | ~69 (`most.cmake` + GPU) |

Both carry the broad `most.cmake` package set (REAXFF, MEAM, ML-SNAP/PACE/POD, DPD-*, GRANULAR, SPIN,
VORONOI, …), link **system Python 3.14** (not conda), and are built against the system OpenMPI
(`openmpi/5.0.10`) so they launch with `srun --mpi=pmix`.

### The one hard lesson: match CUDA to the toolchain

Ubuntu 26.04 ships **GCC 15 + glibc 2.41**. The CUDA toolkit that was preinstalled (**12.9**) cannot
compile against this toolchain — you hit, in sequence: `unsupported GNU version` (nvcc caps at GCC 14),
then C++23 math-header clashes (`cospi`/`sinpi`/`rsqrt` `noexcept` mismatches in glibc 2.41), then
KOKKOS/GPU-package failures on GCC-15's `type_traits`. Patching these one by one is a losing battle.

**The fix is to install CUDA 13.x** (13.0+ officially supports GCC 15). With CUDA 13.3 the entire GPU
build compiles with plain GCC 15 — no compiler shim, no header patches. Do not sink time into making
CUDA 12.9 work here; install 13.x instead.

```bash
# CUDA 13.x installs alongside 12.x under /usr/local/cuda-13.x (coexist, nothing removed).
# NVIDIA's repo on Ubuntu 26.04 provides a rolling cuda-toolkit (13.3 at time of writing):
sudo apt install -y cuda-toolkit-13-3        # or: cuda-toolkit
ls -d /usr/local/cuda-13*                     # confirm the path
# sanity — GCC 15, no -ccbin, no patches:
echo 'int main(){return 0;}' > /tmp/t.cu
/usr/local/cuda-13.3/bin/nvcc /tmp/t.cu -o /tmp/t && echo OK    # must print OK
```

### CPU build (`lammps/stable`)

No CUDA, so no GCC-15/CUDA friction — KOKKOS with OpenMP only, plain GCC 15. Build under Slurm to get
uncapped cores (interactive CPU is capped per user). The key non-obvious flags are the **system-Python
pinning** (see the conda note below).

```bash
git clone -b stable https://github.com/lammps/lammps.git /opt/sw/lammps/src   # once, shared
# build-cpu-full.sh (submitted with sbatch --cpus-per-task=24):
module load openmpi/5.0.10
export PATH=$(echo "$PATH" | tr ':' '\n' | grep -v miniforge | paste -sd:)   # strip conda! (see below)
export PATH=/usr/bin:$PATH
cd /opt/sw/lammps && rm -rf build-cpu-full && mkdir build-cpu-full && cd build-cpu-full
cmake ../src/cmake \
  -C ../src/cmake/presets/most.cmake \
  -D CMAKE_INSTALL_PREFIX=/opt/sw/lammps \
  -D BUILD_MPI=yes -D BUILD_OMP=yes -D CMAKE_CXX_COMPILER=mpicxx \
  -D CMAKE_BUILD_TYPE=Release -D CMAKE_CXX_STANDARD=20 \
  -D PKG_KOKKOS=yes -D Kokkos_ARCH_NATIVE=yes -D Kokkos_ENABLE_OPENMP=yes \
  -D FFT=FFTW3 -D PKG_PYTHON=no \
  -D Python_EXECUTABLE=/usr/bin/python3 -D Python3_EXECUTABLE=/usr/bin/python3 \
  -D Python_ROOT_DIR=/usr -D Python3_ROOT_DIR=/usr -D Python_FIND_STRATEGY=LOCATION \
  -D PKG_ML-PACE=yes -D DOWNLOAD_PACE=yes -D PKG_MDI=yes -D DOWNLOAD_MDI=yes
make -j24 && make install
```

### GPU build (`lammps-gpu/stable`)

Same as above **plus** the CUDA/GPU flags, pointed at **CUDA 13.3**. The GPU is an RTX 4500 Ada →
compute 8.9 → `Kokkos_ARCH_ADA89` and `GPU_ARCH=sm_89`. voro++ (`sudo apt install voro++ voro++-dev`)
provides VORONOI. Build under Slurm (uncapped; ~13 min at `-j24`):

```bash
module load openmpi/5.0.10
export CUDA_HOME=/usr/local/cuda-13.3
export PATH=$(echo "$PATH" | tr ':' '\n' | grep -v miniforge | paste -sd:)
export PATH=/usr/local/cuda-13.3/bin:/usr/bin:$PATH
cd /opt/sw/lammps && rm -rf build-gpu-full && mkdir build-gpu-full && cd build-gpu-full
cmake ../src/cmake \
  -C ../src/cmake/presets/most.cmake \
  -D CMAKE_INSTALL_PREFIX=/opt/sw/lammps-gpu \
  -D BUILD_MPI=yes -D BUILD_OMP=yes -D CMAKE_CXX_COMPILER=mpicxx \
  -D CMAKE_BUILD_TYPE=Release -D CMAKE_CXX_STANDARD=20 \
  -D CUDAToolkit_ROOT=/usr/local/cuda-13.3 \
  -D PKG_KOKKOS=yes -D Kokkos_ARCH_NATIVE=yes -D Kokkos_ARCH_ADA89=yes \
  -D Kokkos_ENABLE_CUDA=yes -D Kokkos_ENABLE_OPENMP=yes -D FFT_KOKKOS=CUFFT \
  -D PKG_GPU=yes -D GPU_API=cuda -D GPU_ARCH=sm_89 -D GPU_PREC=mixed \
  -D FFT=FFTW3 -D PKG_PYTHON=no \
  -D Python_EXECUTABLE=/usr/bin/python3 -D Python3_EXECUTABLE=/usr/bin/python3 \
  -D Python_ROOT_DIR=/usr -D Python3_ROOT_DIR=/usr -D Python_FIND_STRATEGY=LOCATION \
  -D PKG_ML-PACE=yes -D DOWNLOAD_PACE=yes -D PKG_MDI=yes -D DOWNLOAD_MDI=yes
make -j24 && make install
```

> **The conda-Python trap.** `most.cmake` includes ML-IAP, which links **libpython** even with
> `PKG_PYTHON=no`. CMake's `find_package(Python …)` will grab **conda's** Python (`/opt/miniforge3`,
> 3.13) if conda is on `PATH` — producing a binary that fails to start with
> `libpython3.13.so.1.0: cannot open shared object file` unless conda happens to be loaded. The fix is
> two-fold and both parts matter: (1) **strip miniforge from `PATH`** inside the build (the `grep -v
> miniforge` line), so CMake can only find system Python; (2) pin `Python*_EXECUTABLE=/usr/bin/python3`
> and `Python_ROOT_DIR=/usr`. Then the binary links `/usr/lib/x86_64-linux-gnu/libpython3.14.so.1.0`
> (system, standard path) and has **no conda dependency**. Verify with
> `ldd /opt/sw/lammps-gpu/bin/lmp | grep -iE 'not found|python'` — it must show the `/usr/lib` path and
> no "not found". This is easy to miss because the CMake cache will show `PKG_PYTHON=no` while the log
> quietly reports `Found Python: /opt/miniforge3/...` for the Development component.

### Modulefiles

```bash
# CPU
sudo mkdir -p /opt/modulefiles/lammps
sudo tee /opt/modulefiles/lammps/stable.lua > /dev/null << 'EOF'
whatis("Name: LAMMPS (stable) — MD, CPU (MPI + OpenMP), broad package set (68 pkgs)")
depends_on("openmpi/5.0.10")
prepend_path("PATH", "/opt/sw/lammps/bin")
prepend_path("LD_LIBRARY_PATH", "/opt/sw/lammps/lib")
prepend_path("LD_LIBRARY_PATH", "/opt/sw/lammps/lib64")
EOF

# GPU
sudo mkdir -p /opt/modulefiles/lammps-gpu
sudo tee /opt/modulefiles/lammps-gpu/stable.lua > /dev/null << 'EOF'
whatis("Name: LAMMPS-GPU (stable) — MD on RTX 4500 Ada (CUDA 13.3), broad set (69 pkgs)")
depends_on("openmpi/5.0.10")
prepend_path("PATH", "/opt/sw/lammps-gpu/bin")
prepend_path("LD_LIBRARY_PATH", "/opt/sw/lammps-gpu/lib")
prepend_path("LD_LIBRARY_PATH", "/opt/sw/lammps-gpu/lib64")
prepend_path("LD_LIBRARY_PATH", "/usr/local/cuda-13.3/lib64")
setenv("CUDA_HOME", "/usr/local/cuda-13.3")
EOF
chmod -R o+rX /opt/sw/lammps /opt/sw/lammps-gpu
```

### Verify

```bash
module load lammps-gpu/stable
ldd $(which lmp) | grep -i 'not found'                 # must be EMPTY
lmp -h 2>&1 | grep -iE 'Compatible GPU|Installed pack' # GPU: yes; then the package list
cd ~/runs && cp /opt/sw/lammps/src/bench/in.lj .
lmp -sf gpu -pk gpu 1 -in in.lj                        # prints "Device 0: NVIDIA RTX 4500 Ada …"
lmp -k on g 1 -sf kk  -in in.lj                        # KOKKOS/CUDA path
mpirun -np 8 lmp -in in.lj                             # CPU path (same binary)
```

A successful GPU run prints a `Device 0: NVIDIA RTX 4500 Ada Generation …` block — that's the proof it
executed on the card. See `lammps.sh` / `lammps-gpu.sh` in the Slurm templates for batch usage
(GPU jobs use `--gres=gpu:1`, one rank per GPU).

> **Build under Slurm, not interactively.** These are large builds (69 packages + CUDA). Interactive
> CPU is capped per user, so a foreground `make` crawls; submitting the build as a Slurm job gets all
> requested cores **and** is immune to SSH disconnects. The same goes for the auto-download packages
> (`DOWNLOAD_PACE`, `DOWNLOAD_MDI`) which fetch from GitHub during the build — the build network
> allowlist already permits github.com.

---

## CUDA-aware OpenMPI (`openmpi-cuda/5.0.10`) — for GPU codes that MPI on device buffers

The default `openmpi/5.0.10` (both the Spack build and the apt one) is **not CUDA-aware** — built
`--without-cuda --without-ucx`. That's fine for CPU codes, but GPU codes that hand `cudaMalloc`'d
device pointers directly to `MPI_Isend/Irecv` (LBPM's ScaLBL halo exchange is the example) **segfault
instantly** on it — the MPI can't touch device memory, and no runtime env var fixes a capability that
wasn't compiled in. For those codes you need a second, CUDA-aware MPI. Build it with Spack:

```bash
# register the system CUDA 13.3 as a Spack external first (so +cuda doesn't build CUDA):
spack external find --not-buildable cuda
# pin the explicit path in ~/.spack/packages.yaml (avoids the /usr/local/cuda alternatives symlink):
#   cuda:
#     externals: [ { spec: cuda@13.3.73, prefix: /usr/local/cuda-13.3 } ]
#     buildable: false

# build CUDA-aware OpenMPI + UCX (device-buffer transports), arch sm_89:
spack install --reuse \
  openmpi@5.0.10 +cuda +internal-pmix fabrics=ucx cuda_arch=89 \
  ^ucx +cuda +cma cuda_arch=89 \
  ^cuda@13.3.73
```

This coexists with the non-CUDA `openmpi@5.0.10` (different Spack hash). Give it a **distinct module**
so the two never collide — the CUDA one `conflict`s with the plain one, so only one is ever on `PATH`:

```bash
CUDA_MPI=$(spack location -i openmpi +cuda)
UCX_CUDA=$(spack location -i ucx +cuda)
sudo mkdir -p /opt/modulefiles/openmpi-cuda
sudo tee /opt/modulefiles/openmpi-cuda/5.0.10.lua > /dev/null << EOF
whatis("Name: OpenMPI 5.0.10 (CUDA-aware) — +cuda +ucx, for GPU codes doing MPI on device buffers")
family("mpi")
conflict("openmpi")
prepend_path("PATH", "$CUDA_MPI/bin")
prepend_path("LD_LIBRARY_PATH", "$CUDA_MPI/lib")
prepend_path("LD_LIBRARY_PATH", "$UCX_CUDA/lib")
prepend_path("LD_LIBRARY_PATH", "/usr/local/cuda-13.3/lib64")
setenv("MPICC", "$CUDA_MPI/bin/mpicc")
setenv("MPICXX", "$CUDA_MPI/bin/mpicxx")
EOF
```

Verify it's genuinely CUDA-aware (the check the old MPI fails):

```bash
module load openmpi-cuda/5.0.10
ompi_info | grep -iE 'MCA accelerator: cuda|MPI extensions'   # shows cuda accelerator + extension
ucx_info -d | grep -iE 'cuda_copy|cuda_ipc'                    # device-buffer transports present
```

`MCA accelerator: cuda` + UCX `cuda_copy`/`cuda_ipc` = it can carry device pointers. This module is a
reusable building block for **any** future GPU-MPI code, not just LBPM.

---

## Application: LBPM (lattice-Boltzmann porous media, GPU/CUDA)

LBPM does two-phase flow in porous media on the GPU. It's the reason the CUDA-aware MPI above exists —
ScaLBL's halo exchange passes device pointers straight to MPI.

**Build against the CUDA-aware MPI**, with CUDA 13.3 / sm_89, serial HDF5, into `/opt/sw/lbpm`:

```bash
git clone https://github.com/OPM/LBPM.git /opt/sw/lbpm/src
sudo apt install -y libhdf5-dev        # serial HDF5 (/usr/.../hdf5/serial)

# build as a Slurm job (uncapped, disconnect-proof):
module load openmpi-cuda/5.0.10
export CUDA_HOME=/usr/local/cuda-13.3 PATH=$CUDA_HOME/bin:$PATH
cd /opt/sw/lbpm && rm -rf build && mkdir build && cd build
cmake \
  -D CMAKE_INSTALL_PREFIX=/opt/sw/lbpm \
  -D CMAKE_BUILD_TYPE=Release \
  -D CMAKE_C_COMPILER=mpicc -D CMAKE_CXX_COMPILER=mpicxx \
  -D CMAKE_C_FLAGS="-fPIC" -D CMAKE_CXX_FLAGS="-fPIC" -D CMAKE_CXX_STANDARD=17 \
  -D USE_MPI=1 -D MPIEXEC=mpirun \
  -D USE_CUDA=1 -D CMAKE_CUDA_COMPILER=$CUDA_HOME/bin/nvcc \
  -D CMAKE_CUDA_ARCHITECTURES=89 -D CMAKE_CUDA_HOST_COMPILER=$(which g++) \
  -D USE_HDF5=1 -D HDF5_DIRECTORY=/usr/lib/x86_64-linux-gnu/hdf5/serial \
  -D HDF5_ROOT=/usr/lib/x86_64-linux-gnu/hdf5/serial \
  -D USE_SILO=0 -D USE_NETCDF=0 -D USE_TIMER=0 \
  ../src
make -j16 && make install
```

> **The one GCC-15 source fix.** LBPM's `common/Units.h` declares `enum class ... : int8_t/uint8_t`
> but doesn't `#include <cstdint>` — older libstdc++ leaked it in transitively; GCC 15 doesn't. Result:
> a flood of `'UnitValue' has not been declared` / `'d_unit' was not declared` errors. Fix is one line:
> `sed -i 's|#include <array>|#include <cstdint>\n#include <array>|' /opt/sw/lbpm/src/common/Units.h`.
> (Same class of GCC-15 breakage as LaGriT — a missing `<cstdint>`.) Nothing else needed patching.

**Module** (depends on the CUDA-aware MPI):

```bash
sudo ln -sfn /opt/sw/lbpm/build/bin /opt/sw/lbpm/bin      # binaries land in build/bin
sudo mkdir -p /opt/modulefiles/lbpm
sudo tee /opt/modulefiles/lbpm/1.0.lua > /dev/null << 'EOF'
whatis("Name: LBPM 1.0 — Lattice-Boltzmann porous media (GPU/CUDA)")
depends_on("openmpi-cuda/5.0.10")
prepend_path("PATH", "/opt/sw/lbpm/bin")
prepend_path("LD_LIBRARY_PATH", "/usr/local/cuda-13.3/lib64")
setenv("LBPM_BIN", "/opt/sw/lbpm/bin")
setenv("PMIX_MCA_psec", "native")
EOF
chmod -R o+rX /opt/sw/lbpm
```

**Run** — geometry first, then the simulator. A deck needs a `Domain{ Filename=... n=... ReadType=...
ReadValues=... }` block pointing at a segmented `.raw` volume (generate with a script, e.g. the
`CreateBubble.py` in `example/Bubble`), and the deck's `nproc` product must equal the MPI rank count.
Single-rank GPU can run the binary directly (no launcher). A successful run prints a `Lattice update
rate (… MLUPS)` line — that means the timestep loop (and the device-pointer halo exchange) completed.

```bash
module load lbpm/1.0
cd ~/runs/mycase                       # dir with input.db + geometry.raw
lbpm_color_simulator input.db          # single rank on the GPU
# multi-rank (shares the one GPU; nproc in deck must match):
# srun --mpi=pmix -n 4 lbpm_color_simulator input.db
```

See the `lbpm.sh` Slurm template for batch usage (`--gres=gpu:1`).

> **GPU memory bounds the domain.** The RTX 4500 Ada has 24 GB — a 750³ lattice does not fit regardless
> of rank count (multi-rank on one GPU shares, not adds, memory). Develop/validate on ≤256³ crops;
> large domains need multi-GPU hardware (and then the CUDA-aware MPI is doing real inter-GPU transport).

---

## Shared software layout (`/opt/sw`) — team access

Because the apps above build into the shared `/opt/sw` tree (not anyone's home), making them available
to the team is mostly automatic. The pieces that matter:

**Module visibility is global.** `MODULEPATH` is set for every login shell by the `z98` (Spack) and
`z99` (`/opt/modulefiles`) profile.d scripts, so each team member sees `module avail` listing
`openmpi`, `pflotran`, and `moose` — no per-user setup.

**The tree is read-only for users — which is correct.** MOOSE and PFLOTRAN write output next to the
input file by default, so users run from **their own** directories (a job launched from inside the
read-only `/opt/sw` would fail to write its `*_out` file):

```bash
module load moose/dev                       # or: module load pflotran
mkdir -p ~/runs/myjob && cd ~/runs/myjob
cp /opt/sw/moose/test/tests/kernels/simple_diffusion/simple_diffusion.i .   # or write your own
srun --mpi=pmix -n 4 combined-opt -i simple_diffusion.i
```

**Verify as a team member:**

```bash
sudo -iu bob
module load moose/dev && which combined-opt        # → /opt/sw/...
mkdir -p ~/runs && cd ~/runs
cp /opt/sw/moose/test/tests/kernels/simple_diffusion/simple_diffusion.i .
srun --mpi=pmix -n 4 combined-opt -i simple_diffusion.i
```

A successful team-account run is also proof the install is self-contained — a team member can't read
your home directory, so if it works for them, nothing depends on home.

**Confirm the module tree is consistent.** `module avail` should list your app modules plus the
Spack stack — no duplicate/ghost entries:

```bash
module avail                  # expect: moose/dev, pflotran/6.0, openfoam/v2506,
                              #         dolfinx/2026, reaktoro/2026, dolfinx-reaktoro/2026,
                              #         phreeqcrm/3.9.0, openmpi/…, etc.
module purge && module load pflotran/6.0 && which pflotran      # → /opt/sw/pflotran/src/pflotran/pflotran
module purge && module load moose/dev   && which combined-opt   # → /opt/sw/moose/modules/combined/combined-opt
```

If you just added a new modulefile and `module avail`/`module load` still can't see it, Lmod's cache
is stale — `module --ignore_cache avail` (or `module --ignore_cache load <name>`) reads the tree
directly and refreshes it.

If a stale Spack-generated module ever lingers (e.g. a leftover `pflotran` from a removed install),
regenerate the Spack tree with `spack module lmod refresh` — your hand-written `/opt/modulefiles`
entries are independent and unaffected.

**If you did a personal home build earlier** (the optional path above), remove it once `/opt/sw` is
verified, and clear any stale `PETSC_DIR` from your shell init:

```bash
rm -rf ~/software/petsc ~/software/pflotran ~/projects/moose
grep -n PETSC ~/.bashrc ~/.bash_profile ~/.profile /etc/profile.d/* 2>/dev/null
```

---

## Quick reference

```bash
# --- Slurm ---
sinfo                          # nodes / partitions / state
squeue                         # queued + running jobs
sbatch job.sh                  # submit a batch job
srun -N1 -n4 ./prog            # run a quick interactive command
srun --gres=gpu:1 --cpus-per-task=8 --mem=32G --pty bash   # interactive shell in an allocation
scancel <jobid>                # cancel a job
scontrol show node hpc01       # node detail
scontrol show job  <jobid>     # job detail
scontrol update NodeName=hpc01 State=RESUME   # un-drain a node
sacct -j <jobid>               # accounting (if slurmdbd enabled)

# --- Modules / software ---
module avail                   # list available modules
module load gcc/13             # load software
module list                    # what's loaded
module purge                   # unload everything
spack install <pkg>            # build software
spack find                     # installed packages
spack module lmod refresh -y   # regenerate Lmod modules

# --- GPU ---
nvidia-smi                     # driver / GPU status
srun --gres=gpu:1 nvidia-smi   # confirm a GPU allocation works

# --- Remote access (run from a member's machine) ---
ssh hpc01                      # connect (uses ~/.ssh/config)
scp file hpc01:~/              # copy a file in
rsync -avP dir/ hpc01:~/dir/   # sync a directory (resumable)
ssh -L 8888:localhost:8888 hpc01   # tunnel a Jupyter/web port
```

---

## Troubleshooting

- **Node `down` with reason "Low socket\*core\*thread count":** your `NodeName=` hardware in
  `slurm.conf` doesn't match reality. Re-run `sudo slurmd -C` and copy it exactly, or simplify
  to just `CPUs=N`.
- **Node `down`/`drained`:** `sudo scontrol update NodeName=hpc01 State=RESUME`. Check the
  reason with `scontrol show node hpc01`.
- **`srun` hangs or "Invalid credential":** Munge mismatch. Confirm `munge -n | unmunge`
  succeeds and the clock is synced (`timedatectl set-ntp true`).
- **Services won't start:** read the logs —
  `/var/log/slurm/slurmctld.log`, `/var/log/slurm/slurmd.log`,
  and `journalctl -u slurmctld -u slurmd --no-pager`.
- **`module: command not found`:** open a *new* login shell (the init scripts in
  `/etc/profile.d/` only load for login shells), or `source /etc/profile.d/*lmod*.sh`.
- **cgroup errors on start:** confirm cgroup v2 with `stat -fc %T /sys/fs/cgroup`
  (`cgroup2fs`); ensure your Slurm version supports it (recent versions do via `autodetect`).
- **`slurmd` fatal "we weren't able to find that lib when Slurm was configured":** you set
  `AutoDetect=nvml` in `gres.conf`, but the packaged Slurm has no NVML support. Use an explicit
  `Name=gpu File=/dev/nvidiaN` line instead (Step 14.3).
- **`nvidia-smi` fails after install ("couldn't communicate with the NVIDIA driver"):** usually
  Secure Boot blocking the unsigned kernel module — complete MOK enrollment or disable Secure
  Boot, then confirm the module loaded with `lsmod | grep nvidia`.
- **A job can't see the GPU / "no devices":** make sure you requested it (`--gres=gpu:1`) and
  that the `gres.conf` `File=` path matches `ls /dev/nvidia*`.
- **Locked out over SSH after hardening:** you disabled `PasswordAuthentication` before a key
  worked, or ran `ufw enable` without an SSH rule. Recover at the physical console — re-add the
  key or re-enable password auth, and `sudo ufw allow OpenSSH`.
- **Can't reach the box remotely:** the address changed (set a DHCP reservation), the VPN isn't
  up (`tailscale status`), or UFW/the router is blocking the port.
- **`spack: command not found`:** the setup script hasn't been sourced in this shell. Run
  `source /etc/profile.d/spack.sh` (or open a new login shell).
- **Spack build fails with `<lib> is a must but can not be found`, `library (z) in /usr... not
  found`, or `<header>.h: No such file or directory`:** Spack is reusing a system library
  registered by `spack external find` that's missing dev files or sits in Ubuntu's multiarch lib
  path. Fix: `spack config edit packages`, delete that library's block (keep `gcc:` and tool
  entries), and re-run so Spack builds its own. On a brand-new OS, prefer the apt stack in Step 10.
- **Spack `cannot create lock … location is not writable`:** `/opt/spack` is root-owned (you
  cloned it with sudo). Hand it to your user: `sudo chown -R $USER:$USER /opt/spack`, and never run
  `spack` with sudo.
- **`slurmd`/`slurmctld` fatal `Duplicated NodeName hpc01 in the config file`:** you have two
  `NodeName=hpc01` lines in `slurm.conf` (e.g. the GPU edit added a second one instead of editing
  the existing line). Keep only one — the line with `Gres=gpu:1` — and restart.
- **`slurmctld` fatal `slurmdbd is required to run with TRES gres/gpu`:** you set
  `AccountingStorageTRES=gres/gpu` without setting up slurmdbd. Remove that line (GPU scheduling
  doesn't need it), or set up slurmdbd accounting (Optional A) and keep it.
- **PFLOTRAN: "Direct solver (KSPPREONLY + PCLU) not supported when running in parallel":** the
  input deck asks for a direct LU solve, which PETSc's built-in LU only does serially. Run it on
  `-n 1`, switch the deck to an iterative solver, or rebuild PETSc with
  `--download-mumps=yes --download-scalapack=yes`.
- **PFLOTRAN won't compile (`/conf/variables: No such file or directory`):** `PETSC_DIR`/
  `PETSC_ARCH` aren't set (or point at the wrong arch). Export both (PFLOTRAN section, Route 2
  step 3); the real arch name is the directory under `$PETSC_DIR/` and in `configure.log`.
- **PMIx "psec / Component: munge" warnings on `srun --mpi=pmix`:** harmless on a single node —
  PMIx probes for a munge security plugin, doesn't find that component, and falls back to native
  auth. Silence with `export PMIX_MCA_psec=native` (the PFLOTRAN/MOOSE modulefiles set this for you).
- **MOOSE/PETSc build: `PTScotch needs flex installed`:** install `flex` and `bison` (plus
  `libtool autoconf automake m4` to be safe) and re-run `update_and_rebuild_petsc.sh`.
- **MOOSE/libMesh build: `XDR was not found, but --enable-xdr-required was specified`:** modern
  glibc dropped built-in Sun RPC/XDR. Install `libtirpc-dev` and re-run `update_and_rebuild_libmesh.sh`.
- **MOOSE/WASP: `git submodule … HTTP 403` from `code.ornl.gov`:** transient throttling on ORNL's
  GitLab. Retry, fetch the wasp submodules one at a time, or skip the test-only ones
  (`git config submodule.testframework.update none`, same for `googletest`) — only TriBITS is needed
  to build.
- **MOOSE `run_tests`: `ModuleNotFoundError: No module named 'numpy'`:** the Python test harness
  needs numpy (and pandas/scipy/pyyaml/jinja2). `pip install` them into the python `run_tests` uses.
  The build itself is fine — `./moose_test-opt --help` confirms the executable regardless.
- **`Failed to open file …_out.e` when a team member runs an app:** they launched from inside the
  read-only `/opt/sw` tree, where output can't be written. MOOSE/PFLOTRAN write next to the input by
  default, so users should copy the deck into their own directory (`~/runs/...`) and run there. Not a
  permissions bug — the shared tree is *supposed* to be read-only for users.
- **DOLFINx parallel run hangs or errors with `srun --mpi=pmix`:** the conda DOLFINx env uses
  **MPICH**, which speaks PMI/PMI2, not PMIx. Launch with the env's own `mpirun -n N python …` or
  `srun --mpi=pmi2`. `--mpi=pmix` is for your OpenMPI-built codes (PFLOTRAN, MOOSE), not this env.
- **`sudo tee /opt/modulefiles/<app>/<ver>.lua` fails with `No such file or directory`:** `tee`
  doesn't create parent directories. Run `sudo mkdir -p /opt/modulefiles/<app>` first (every
  modulefile block above does this). The env/build can succeed while the modulefile silently never
  got written — symptom is "unknown module" on the next line.
- **`Lmod has detected the following error: The following module(s) are unknown` right after adding
  a modulefile:** either the file wasn't actually written (see the `tee` entry above — check with
  `cat /opt/modulefiles/<app>/<ver>.lua`), or Lmod's cache is stale. Refresh with
  `module --ignore_cache avail` / `module --ignore_cache load <name>`. The `#%Module` hint in that
  error is a generic Lmod message for old TCL files and doesn't apply to `.lua` modulefiles.
- **OpenFOAM `git clone` returns 403 / `Host not in allowlist`:** the core repos are on
  `gitlab.com/openfoam` now (migrated from `develop.openfoam.com`). Confirm tags with
  `git ls-remote --tags https://gitlab.com/openfoam/core/openfoam.git`; the GitHub `OpenFOAM/*`
  mirrors are the **openfoam.org** fork and lag behind, so don't use them for an openfoam.com build.
- **OpenFOAM `Allwmake` ignores your MPI / builds its own OpenMPI:** `WM_MPLIB` is still the default.
  Set `WM_MPLIB=SYSTEMMPI` in `etc/bashrc`, export `MPI_ARCH_INC`/`MPI_ARCH_LIBS`/`MPI_ARCH_FLAGS`
  pointing at the loaded module, `source etc/bashrc` again, and check `echo $FOAM_MPI` before
  rebuilding. `foamSystemCheck` must say PASS first.
- **`ldd $(which simpleFoam)` shows `libmpi.so.40 => /usr/lib/x86_64-linux-gnu/…` instead of Spack:**
  a SYSTEMMPI build records no rpath, so the runtime linker finds the apt OpenMPI (often pulled in by
  `libptscotch-dev`) before your Spack one. Even if both are the same version, force the Spack lib
  first: the `openfoam` modulefile prepends `…/openmpi-5.0.10-…/lib` to `LD_LIBRARY_PATH` (see the
  modulefile). Verify after loading: `ldd $(which simpleFoam) | grep mpi` should resolve into
  `/opt/spack/…`. Don't `apt remove` the apt OpenMPI — it's a dependency of the scotch/co-array
  packages and removing it cascades.
- **OpenFOAM parallel run dies with `Attempted to use <scotch> without the scotchDecomp library
  loaded … dummy scotchDecomp stub`:** OpenFOAM only built the *dummy* scotch wrapper because its
  default config wanted a ThirdParty `scotch_6.1.0` that the `ThirdParty-common` repo doesn't ship.
  Fix: edit `etc/config.sh/scotch` to `SCOTCH_TYPE=system` + `SCOTCH_ARCH_PATH=/usr`, symlink the apt
  header (`sudo ln -sf /usr/include/scotch/scotch.h /usr/include/scotch.h`, same for `ptscotch.h`),
  re-`source etc/bashrc` (confirm `echo $SCOTCH_ARCH_PATH` prints `/usr`), then
  `src/parallel/decompose/Allwmake`. Setting `SCOTCH_TYPE=system` only in the shell does **not** work
  — sourcing `etc/bashrc` reads `config.sh/scotch` and overwrites it. The real `libscotchDecomp.so`
  lands in `$FOAM_LIBBIN`, the parallel one in `$FOAM_LIBBIN/sys-mpi/`.
- **OpenFOAM `decomposePar` → `Wrong number of domain divisions … Wanted decomposition : (3 3 1)`:**
  `numberOfSubdomains` doesn't match the decomposition method's coeffs. The cavity tutorial ships
  `method hierarchical; coeffs (3 3 1)` = 9 domains. Either set `numberOfSubdomains` to the product of
  the coeffs, make the coeffs multiply to your rank count (e.g. `(2 2 1)` for 4), or switch to
  `method scotch;` which needs no coeffs. Use `decomposePar -force` to overwrite a partial decompose.
