# Alliance HPC Cluster — Login Pod Guardrails

You are running inside a **per-user Slurm login pod** (`login-<user>`) on a Digital Research Alliance of Canada (DRAC) HPC cluster. Your pod has a **small, fixed CPU and RAM cgroup slice** — submit all compute, builds, training, and inference through Slurm (`sbatch` / `salloc`), never inside the login pod.

## First 30 seconds

1. **Read `/etc/agents/site.md` first** (if present) for this cluster's partitions, GPU/MIG types, `--account` rules, storage paths, portal URLs, and site status command name.
2. **Check live cluster state & notices:** run `cluster-status --plain` (or the site status command listed in `/etc/agents/site.md`, exposed on `PATH` via `/etc/cluster-status/bin`) to inspect active announcements, free CPUs/GPUs, storage usage, and queue state.
3. **Check your pod slice:** run `login-pod status` to see `$LOGIN_JOB_ID`, node placement, CPU/memory limits, and remaining walltime.

## Essential in-pod commands

| Command | Purpose |
|---|---|
| `cluster-status --plain` | Live node/GPU availability, operator announcements, quotas, and pod summary (non-interactive friendly) |
| `login-pod status` | Show your login pod's Slurm JobId (`$LOGIN_JOB_ID`), node (`$LOGIN_POD_NODE`), cgroup limits, and time left |
| `login-pod restart` | Tear down and respawn your pod on next login (e.g. to pick up new POSIX group memberships) |
| `sq` | Compact view of your queued and running Slurm jobs (`squeue --me`) |
| `seff <jobid>` | Post-run CPU and memory efficiency report for a completed job |
| `diskusage_report` | Quota and file-count usage across `$HOME`, `$SCRATCH`, and `$PROJECT` |
| `module spider <name>` | Search the full CVMFS/Lmod software catalog before `module load` |
| `agent-guardrails status` | Check active AI guardrail links and list opt-in skills (`agent-guardrails list-community`) |

## Login pod environment & persistence

- **Key environment variables:** `$LOGIN_SESSION_MODE` (`login`, `robot`, or `admin`), `$LOGIN_JOB_ID` (your pod's Slurm JobId), `$LOGIN_POD_NODE`, and `$CC_CLUSTER`.
- **Disconnect survival:** Your login pod and its `tmux` server persist across SSH disconnects until the pod walltime expires. Use `tmux new -As work` for long interactive workflows.
- **Never `scancel` your own `login-*` job (`$LOGIN_JOB_ID`)!** Cancelling `$LOGIN_JOB_ID` terminates the container running your shell and kills this agent immediately.
- **No agents on `robot.*`:** AI coding agents are prohibited in unattended `robot` sessions (`LOGIN_SESSION_MODE=robot`).

## Hard rules

- **No heavy compute in the login pod:** Do not run training, inference, simulations, multi-core builds (`make -j`), or heavy package compiles locally; offload to `sbatch` or `salloc`.
- **Keep job I/O and caches off `$HOME`:** Direct datasets, checkpoints, virtualenvs, `HF_HOME`, `PIP_CACHE_DIR`, and `UV_CACHE_DIR` to `$SCRATCH` or job-local `$SLURM_TMPDIR`.
- **No broad filesystem scans:** Never run `find`, `du`, or `rg` across `/`, `/home`, `/scratch`, or `/project*` roots — scope to a specific project subdirectory.
- **No tight Slurm polling:** Poll `sq` / `squeue` no faster than every 2–5 minutes, or use `sbatch --wait` for short test jobs.
- **Never guess modules or GPUs:** Verify exact versions with `module spider <pkg>` and GPU GRES strings with `sinfo -o "%N %P %G" --Node | sort -u` ( plus `/etc/agents/site.md`).
- **Privacy, credentials, and multi-tenancy:** Never access other users' directories under `/home`, `/scratch`, or `/project*`; never read `~/.ssh`, `.env*`, tokens, `.netrc`, `/etc/shadow`, or `/etc/sssd`; never enumerate accounts (`getent passwd`, `ldapsearch`); do not send restricted or unpublished research data to external AI APIs without explicit user authorization.

## Minimal Slurm templates

Check `sacctmgr -nP show assoc where user="$USER" format=account` (and `/etc/agents/site.md`) to see whether `--account=` is required on this cluster.

```bash
# CPU batch job (submit with: sbatch job_cpu.sh)
#!/bin/bash
#SBATCH --job-name=cpu-work
#SBATCH --cpus-per-task=4
#SBATCH --mem=16G
#SBATCH --time=01:00:00
#SBATCH --output=%x-%j.out

module purge
# module load python/3.11 scipy-stack   # verify with: module spider python
virtualenv --no-download "$SLURM_TMPDIR/venv"
source "$SLURM_TMPDIR/venv/bin/activate"
pip install --no-index --upgrade pip
python my_script.py --out "$SCRATCH/results/$SLURM_JOB_ID"
```

```bash
# GPU batch job — check typed GRES in /etc/agents/site.md or sinfo -o "%N %P %G" --Node
#!/bin/bash
#SBATCH --job-name=gpu-work
#SBATCH --gpus-per-node=1
#SBATCH --cpus-per-task=4
#SBATCH --mem=32G
#SBATCH --time=02:00:00
#SBATCH --output=%x-%j.out

nvidia-smi
srun python train.py --data "$SCRATCH/data" --ckpt "$SCRATCH/runs/$SLURM_JOB_ID"
```

For quick interactive testing on a compute node: `salloc --cpus-per-task=2 --mem=8G --time=00:30:00`.

## Installed Alliance skills

Invoke or consult: `alliance-slurm`, `alliance-cvmfs`, `alliance-docs` (https://docs.alliancecan.ca), `alliance-arbutus`, and `alliance-gitlab`. Additional opt-in research skills (`alliance-jax`, `alliance-containers`, `alliance-storage`, `alliance-rac`, etc.) can be installed per user via `agent-guardrails install-community <skill>`.
