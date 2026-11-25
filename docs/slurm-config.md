# Slurm, Pyxis, Enroot & `job_submit.lua` Configuration

Reference snippets live in [`slurm/`](../slurm/).

## 1. Login Partition (`slurm.conf`)

Define a dedicated `login` partition (`Default=NO`, `OverSubscribe=FORCE:16`, `MaxTime=7-00:00:00`) backed by your login-pod execution nodes (which may be the gateway VMs themselves or dedicated login-pod worker nodes):

```ini
NodeName=login-pod[1-2] CPUs=16 RealMemory=64000 State=UNKNOWN
PartitionName=login Nodes=login-pod[1-2] Default=NO MaxTime=7-00:00:00 DefaultTime=7-00:00:00 OverSubscribe=FORCE:16 DefMemPerCPU=1024 State=UP
```

Key `slurm.conf` parameters to verify:
- **`RealMemory`, `MemSpecLimit` & `CoreSpecCount`:** Reserve gateway OS/daemon headroom (`MemSpecLimit=4096` or `8192`) while exposing actual host RAM in `RealMemory` and enabling `OverSubscribe=FORCE:16` (or `OverSubscribe=YES` with `POD_OVERSUBSCRIBE="1"` in `login-gateway.conf`) so lightweight idle pods pack cleanly without starving `sshd` or `slurmd`. `spawn` automatically prefers the local gateway node when it has free memory and falls back across the `login` partition otherwise.
- **`PrologFlags=Contain`:** Required for `job_container/tmpfs` and clean cgroup attachment.
- **Rootless per-user UTS hostnames (`/etc/enroot/hooks.d/50-login-pod-hostname.sh`):** Installed automatically by `deploy/warewulf/render-overlays.sh` and `deploy/standalone/install.sh` so unprivileged `login-<user>` pods get `<cluster>-login-<user>` in `hostname`, `/etc/hostname`, and `/etc/hosts` (`127.0.1.1`).
- **Safe SquashFS image updates (`deploy/warewulf/import-image.sh`):** Never overwrite an in-use `.sqsh` file mounted by running `squashfuse` pods; always import to a new versioned filename (`slurm-login-pods-<ver>.sqsh`) and update `IMAGE_PATH` / `ADMIN_IMAGE_PATH`.
- **`SrunPortRange=60001-63000`** (if host firewalls restrict internal ports): Keep `PORT_MIN=20000` / `PORT_MAX=29999` in `login-gateway.conf` disjoint from `SrunPortRange` so in-pod `sshd` ports never collide with `srun` step IO ports.
- **`SelectType=select/cons_tres`** with `SelectTypeParameters=CR_Core_Memory` and `JobAcctGatherType=jobacct_gather/cgroup`.

## 2. Per-Pod Private `/tmp` & `/dev/shm` (`job_container.conf`)

Enable `JobContainerType=job_container/tmpfs` in `slurm.conf` and configure [`slurm/job_container.conf.example`](../slurm/job_container.conf.example):

```ini
AutoBasePath=true
BasePath=/var/nvme/slurm-tmpfs
Shared=true
```

`Shared=true` allows Pyxis and multiple steps within the same `login-<user>` job to share the pod's private `/tmp` (where `/tmp/sshd`, `/tmp/run-$UID`, and `/tmp/cluster-status` live) while completely isolating `/tmp` between different users' pods on the same host.

## 3. Pyxis SPANK Plugin (`plugstack.conf.d/pyxis.conf`)

Install `spank_pyxis.so` on every `login` partition node (and compute nodes if users run containers in batch jobs):

```text
required /usr/lib/x86_64-linux-gnu/slurm/spank_pyxis.so runtime_path=/run/pyxis execute_entrypoint=0 container_scope=job sbatch_support=1
```

Ensure `squashfuse` is installed and `user.max_user_namespaces = 65536` is enabled (`deploy/ansible/05-enroot-pyxis-node.yaml`) so unprivileged `login-<user>` and `robot-<user>` pods mount `.sqsh` images via FUSE without root privileges.

## 4. `job_submit.lua` Exemption

Alliance clusters typically require `--account=def-...` on all batch/interactive jobs via `job_submit.lua` and auto-route jobs without `--partition`. Because `spawn` submits `login-*`, `robot-*`, and `admin-*` jobs before a researcher chooses an allocation account, **exempt the `login` partition at the top of `slurm_job_submit`** (see [`slurm/job_submit.lua.example`](../slurm/job_submit.lua.example)):

```lua
if job_desc.partition == "login" then
    return slurm.SUCCESS
end
```
