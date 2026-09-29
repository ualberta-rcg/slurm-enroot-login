# slurm-enroot-login

A portable HPC **login userland** — the container image users land in when
they SSH to a cluster that runs interactive logins as Slurm jobs via the
**pyxis + enroot** stack (see the gateway/login-jobs design).

Named for what it is: **slurm** (clients inside; launched from jobs) +
**enroot** (rootless runtime that imports and executes it) + **login**
(interactive userland, not a batch payload image). Works on any cluster
using this pattern — no site specifics baked in.

## What's inside

* Ubuntu 24.04 base, no slurmd/slurmctld daemons, no kernel, no GPU drivers
* Slurm **client** tools (`srun`/`sbatch`/`salloc`/`squeue`…) — DEBs built by
  [ualberta-rcg/warewulf-slurmd](https://github.com/ualberta-rcg/warewulf-slurmd)
  (`slurm-debs/`, `*_u2404`), staged at build time
* OpenMPI (`mpirun` for small smoke tests), environment-modules, common
  interactive tooling
* `/usr/local/bin/login-shell` — entrypoint that scrubs the job environment
  (`SLURM_*`/`PMI*`/MPI vars) so clients behave exactly as on a traditional
  login node (see design: users' `sbatch` must allocate *new* jobs, not steps)

## Hard rule: NO SECRETS

This repo and its image are **public**. Nothing site-specific or secret is
ever baked in. Every secret/site item is injected at **runtime** — the
tracking list lives in [SECRETS.md](SECRETS.md). CI enforces the basics
(`test-image.yml` scans for key/credential patterns and fails the build on
a hit).

## Build & push

`.github/workflows/build-push-workflow.yml` — same pattern as the sibling
repos (`vulcan-slurm`, `warewulf-slurmd`):

* Trigger: push to `main` (Dockerfile / workflows / login-shell), or manual
  dispatch with optional `SLURM_VERSION_OVERRIDE`
* Version detection: newest `slurm-smd_*_amd64_u2404.deb` committed in the
  warewulf-slurmd repo (no API calls — plain `git clone` + `sort -V`)
* Pushes to Docker Hub: `:<version>` (pinned) and `:latest` (floating)
  using the repo's `DOCKER_HUB_REPO` / `DOCKER_HUB_USER` vars and
  `DOCKER_HUB_TOKEN` secret, exactly like `vulcan-slurm`

## Usage (cluster side)

```
enroot import -o /cache/slurm-enroot-login.sqsh docker://rkhoja/slurm-enroot-login:latest
srun --jobid=<login-job> --overlap --container-image=/cache/slurm-enroot-login.sqsh \
     --container-mounts=/home/$USER,/scratch/$USER,/run/munge,/run/slurm/conf \
     /usr/local/bin/login-shell
```
