# Security Model & Containment Boundaries

## What `slurm-login-pods` Isolates (and What It Does Not)

Enroot + Pyxis + Slurm `cgroup/v2` provide **resource isolation, private mount/UTS namespaces, and filesystem scoping** — they are **not** a hostile-kernel virtualization boundary like KVM/Kata.

### Enforced Boundaries

1. **CPU, Memory & Fork-Bomb Isolation (`cgroup/v2`):**
   Every `login-<user>` pod runs inside its own Slurm job cgroup (`LOGIN_CPUS`, `LOGIN_MEM`). A runaway compiler, Python process, or AI coding agent can only OOM-kill or throttle that single user's pod; gateway `sshd` and other users' pods are unaffected.
2. **Scoped Filesystem Mounts (`--container-mounts`):**
   `spawn` mounts only `/home/<user>`, `/scratch/<user>`, and `/project(s)/<group>` directories for POSIX groups `<user>` actually belongs to — other users' `/home/*` and `/scratch/*` directories are not even mounted inside `login-<user>` pods.
3. **Private `/tmp`, `/dev/shm` & `XDG_RUNTIME_DIR`:**
   `job_container/tmpfs` gives each pod job a private tmpfs `/tmp`. Ephemeral SSH keys (`/tmp/sshd`), runtime sockets (`/tmp/run-$UID`), and status caches (`/tmp/cluster-status`) cannot be observed across pods and vanish when the job ends.
4. **Privilege Escalation Boundary (`dispatch` -> `sudo route`):**
   - `dispatch` runs unprivileged as the authenticated user.
   - `route` runs as `root` via `/etc/sudoers.d/login-gateway` (`NOSETENV` — user environment cannot override `PATH`, `LD_PRELOAD`, or `LOGIN_GATEWAY_CONF`) and trusts **only** `SUDO_USER` from `sudo`. Callers cannot pass another username on the command line.
   - Site hooks (`/etc/login-gateway/hooks/*`) are executed by `route` **only** after verifying the hook file is owned by `0:0` (`root:root`) and not group/world-writable.
5. **Containment Sentinel (`/etc/slurm-login-pods-release`):**
   If Pyxis/Enroot ever fails to enter the container namespace and falls through to host execution, `container-sshd-entrypoint` and `login-shell` detect the missing `/etc/slurm-login-pods-release` sentinel (and host mount namespace match) and immediately abort with exit code `78` instead of starting an uncontained `sshd` on the execution node.
6. **Elimination of Internal SSH MITM/Spoofing:**
   Each pod generates a fresh `ed25519` host key in private `/tmp/sshd` and publishes its SHA256 fingerprint to the Slurm job `Comment` (`<node>:<port>:<sha256>`). `route` pins that exact key before connecting, preventing port-squatting on shared execution hosts.

### Non-Goals / Optional Host Hardening

- **Shared Linux kernel:** User namespaces share the execution node's kernel. Keep execution node kernels patched and run `login` partition pods on dedicated login-pod VMs/nodes rather than privileged management nodes.
- **Process visibility (`/proc`):** By default inside a shared PID namespace on a node, `/proc` may list host PIDs unless mounted with `hidepid=invisible`. Operators who want strict PID hiding across pods without breaking Slurm step tracking can add a `/proc` `hidepid=2` mount hook in `/etc/enroot/mounts.d/` on login-pod worker nodes.
- **Accurate `free -h` inside pods:** Linux `/proc/meminfo` shows host RAM inside containers unless `lxcfs` is mounted over `/proc/meminfo`. `cluster-status` and `login-pod status` read accurate cgroup limits directly from Slurm / `/sys/fs/cgroup`; sites wanting `free`/`top` to reflect `LOGIN_MEM` can enable `lxcfs` bind mounts on login-pod nodes.
