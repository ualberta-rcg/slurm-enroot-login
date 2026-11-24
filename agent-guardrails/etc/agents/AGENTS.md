# Alliance HPC Cluster — Login Pod Guardrails

You are running inside a **per-user Slurm login pod** (`login-<user>`) on a Digital Research Alliance of Canada (DRAC) HPC cluster.

- Your session runs inside an isolated container with a **small, fixed CPU and RAM slice** (check `login-pod status` or `cluster-status` for exact limits).
- **Never run heavy compute, model training, inference, simulations, or multi-core builds inside the login pod** — the pod cgroup will throttle or OOM-kill your session. Submit all compute workloads through Slurm (`sbatch` / `salloc`).
- **AI coding agents are strictly prohibited on MFA automation (`robot.*`) nodes** per Alliance automation policy. Only run agents inside interactive `login-<user>` pods or interactive compute allocations.

**Check site-specific notes first.** If `/etc/agents/site.md` exists on this cluster, read it immediately before submitting jobs — it defines local partition rules, GPU models/MIG shards, default walltimes, storage quotas, and local portal URLs.

**Use the installed Alliance skills:**
- `alliance-slurm` — job scripts, GPUs/GRES, accounts, QOS, and queue inspection
- `alliance-cvmfs` — CVMFS software stack, `module spider`, Lmod, and Python virtualenvs
- `alliance-docs` — current Digital Research Alliance documentation lookup
- `alliance-arbutus` — Arbutus OpenStack cloud and Terraform
- `alliance-gitlab` — `git.computecanada.ca` workflows

## Hard rules — shared cluster & resource-capped login pod

- **Do not run compute, compile large trees, or `pip install` heavy packages directly in the login pod.** Offload to an `sbatch` job or `salloc` interactive allocation.
- **Do not write job output, datasets, or caches to `$HOME`.** `$HOME` has a strict quota; direct all job I/O, caches (`HF_HOME`, `XDG_CACHE_HOME`), and virtualenvs to `$SCRATCH` or `$SLURM_TMPDIR`.
- **Do not scan shared filesystems broadly.** Running `find` across `/`, `/home`, `/scratch`, or `/project` hammers shared metadata servers. Scope searches to a specific subdirectory.
- **Do not poll Slurm in a tight loop.** Use `sbatch --wait` or check `sq` / `squeue -u "$USER"` at multi-minute intervals, never every few seconds.
- **Do not guess cluster parameters.** Verify module versions (`module spider <name>`), GPU GRES names (`sinfo -o "%G" --Node | sort -u`), partitions (`sinfo -s`), and quotas (`diskusage_report`) before acting.
- **Do not enter other users' directories** under `/home`, `/scratch`, or `/project*`.
- **Do not read credentials** (`~/.ssh`, `.env`, tokens, `.netrc`, shell histories, `/etc/shadow`, `/etc/sssd`).
- **Do not enumerate users or collect PII** (`getent passwd`, `ldapsearch`, or scraping other researchers' names, emails, or usernames).
- **Do not expose restricted or unpublished research data** in prompts sent to external AI providers unless the user has explicitly confirmed authorization.

## Two rules that prevent most Slurm failures

1. **Never guess module versions.** Run `module spider <name>` before `module load`. Load modules explicitly inside every `#SBATCH` script.
2. **Never guess GPU types.** Inspect `sinfo -o "%N %P %G" --Node | sort -u` (and `/etc/agents/site.md` if present) and request explicit typed GRES (`--gres=gpu:<model>:<count>`), unless site documentation specifies otherwise.

## Slurm essentials

- Always specify `--cpus-per-task`, `--mem`, `--time`, and `--account` (if required by the cluster's `job_submit.lua` plugin — check `sacctmgr -nP show assoc where user=$USER format=account`).
- Request only the CPUs, memory, GPUs, and walltime the workload actually needs; over-requesting increases queue wait time.
- Use `sq` to inspect your active jobs, `seff <jobid>` to review CPU/RAM efficiency of completed jobs, and `login-pod status` to inspect your login pod's remaining walltime and node placement.
- If you were recently added to a new project group, run `login-pod restart` from a fresh SSH login so your pod picks up updated supplementary groups.

## Software (CVMFS via Lmod)

- `module spider <pkg>` searches the entire CVMFS software tree; `module avail` only shows currently unlocked compiler/MPI tiers.
- Python workflow: `module load python/<ver>`, create virtualenvs on `$SCRATCH` or inside `$SLURM_TMPDIR` using `virtualenv --no-download`, and install wheels from the Alliance wheelhouse with `pip install --no-index <pkg>`.
- Compute nodes may not have direct outbound internet access; stage datasets, models, and wheels before submitting batch jobs.

## Storage layout

| Filesystem | Typical Path | Purpose | Backed Up |
|---|---|---|---|
| `$HOME` | `/home/<user>` | Source code, small configs, scripts | Typically yes |
| `$SCRATCH` | `/scratch/<user>` (`~/scratch`) | Active job I/O, checkpoints, caches (subject to purge) | No |
| `$PROJECT` | `/project/...` or `/projects/...` (`~/projects`) | Shared group datasets & curated results | Site-dependent |
|Pod `/tmp` | `/tmp` (inside login pod) | Ephemeral pod-private scratch (`XDG_RUNTIME_DIR`); wiped when pod stops | No |
| Job `$SLURM_TMPDIR` | Node-local scratch in compute jobs | High-IOPS per-job temporary files; wiped at job end | No |

Check quota usage before large writes with `diskusage_report`.

## Alliance resources

| Resource | Location |
|---|---|
| Alliance Technical Documentation | https://docs.alliancecan.ca |
| Alliance Support | support@tech.alliancecan.ca |
| Local cluster URLs & status | Run `cluster-status` or check `/etc/agents/site.md` |
