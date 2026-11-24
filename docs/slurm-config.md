# Slurm, Pyxis, Enroot & `job_submit.lua` Configuration

Reference snippets live in [`slurm/`](../slurm/).

## 1. Login Partition (`slurm.conf`)

Define a dedicated `login` partition (`Default=NO`, `OverSubscribe=FORCE:16`, `MaxTime=7-00:00:00`) backed by your login-pod execution nodes (which may be the gateway VMs themselves or dedicated login-pod worker nodes):

```ini
NodeName=login-pod[1-2] CPUs=16 RealMemory=64000 State=UNKNOWN
PartitionName=login Nodes=login-pod[1-2] Default=NO MaxTime=7-00:00:00 DefaultTime=7-00:00:00 OverSubscribe=FORCE:16 DefMemPerCPU=1024 State=UP
```

Key `slurm.conf` parameters to verify:
- **`PrologFlags=Contain`:** Required for `job_container/tmpfs` and clean cgroup attachment.
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
