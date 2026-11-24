# Architecture & Pod Lifecycle

## Design Goals

1. **Per-user fault isolation:** Every interactive user gets a dedicated Slurm job (`login-<user>`) constrained by Slurm `cgroup/v2` CPU, memory, and PID limits plus `job_container/tmpfs` private `/tmp` and `/dev/shm`.
2. **Full OpenSSH fidelity:** Multiplexing (`ControlMaster`), VS Code / Cursor / JetBrains Remote-SSH, `tmux` persistence across disconnects, X11 forwarding, SSH agent forwarding, and port forwarding all work unchanged because the pod runs a real `sshd` bound to an internal port (`20000–29999`).
3. **Zero-latency file transfers:** `scp`, `sftp`, `rsync --server`, and `rrsync` execute directly on the gateway inside `login-gateway-xfer.slice` without waiting for or waking a Slurm pod.
4. **Strict site separation:** Generic Alliance mechanisms live in this repository; site authentication shims, storage provisioning, and branding plug in via `/etc/login-gateway/login-gateway.conf`, `/etc/login-gateway/hooks/*`, `/etc/cluster-status/*`, and `/etc/agents/site.md`.

## Components

| Component | Location | Runs As | Responsibility |
|---|---|---|---|
| `dispatch` | `/usr/local/libexec/login-gateway/dispatch` | Authenticated user | `ForceCommand` (login) or rewritten `command=` (robot) entry point. Classifies transfers onto the gateway fast-path; delegates everything else to `sudo -n route`. |
| `classify-transfer` | `/usr/local/libexec/login-gateway/classify-transfer` | Sourced by `dispatch` | Validates `scp -t/-f`, `sftp-server`, `rsync --server`, `rrsync`, and Alliance CVMFS `transfer_commands.sh` / `allowed_commands.sh` wrappers. |
| `route` | `/usr/local/libexec/login-gateway/route` | `root` (via `sudo`) | Resolves identity from `SUDO_USER` (or `hooks/identity` for `SHIM_USERS`), handles `/etc/nologin`, runs `hooks/provision`, invokes `spawn`, pins the pod's host key, and proxies stdio (`ssh -W` or direct `ssh`) to the pod's `sshd`. |
| `spawn` | `/usr/local/libexec/login-gateway/spawn` | `root` | Acquires `/run/login-gateway/locks/<mode>-<user>.lock`, reuses any healthy running pod (`Comment=<node>:<port>:<sha256>`), or submits a new Slurm `srun --container-image=...` job and waits for TCP readiness. |
| `container-sshd-entrypoint` | `/usr/local/bin/container-sshd-entrypoint` (in image) | User (inside pod) | Verifies `/etc/slurm-login-pods-release` containment, applies UTS pod hostname, creates `/tmp/run-$UID` (`0700`) and `/tmp/cluster-status` (`0700` + jittered 10-min baker), generates ephemeral `sshd` keys in `/tmp/sshd`, publishes `<node>:<port>:<fp>` to Slurm job `Comment`, and supervises `sshd -D`. |
| `admin-container-sshd-entrypoint` | `/usr/local/bin/admin-container-sshd-entrypoint` (in admin image) | `root` (inside admin pod) | Same lifecycle for `admin-<user>` pods (`ENROOT_ALLOW_SUPERUSER=yes`), writing `Defaults !fqdn` and `/etc/hosts` for the custom UTS hostname so `sudo -i` and `su - <user>` work seamlessly. |

## Pod Lifecycle

1. **Cold start (~1.5–3 s):** First interactive `ssh user@login.<cluster>` triggers `dispatch -> sudo route -> spawn`. `spawn` submits `srun --partition=login --job-name=login-<user> --container-image=/cache/slurm-login-pods.sqsh --container-unshare=uts ... /usr/local/bin/container-sshd-entrypoint`.
2. **Discovery & TOFU-free pinning:** Inside the pod, `container-sshd-entrypoint` generates `/tmp/sshd/ssh_host_ed25519_key`, starts `sshd` on a free port in `PORT_MIN..PORT_MAX`, and runs `scontrol update JobId=$SLURM_JOB_ID Comment=<physical_node>:<port>:<sha256_fp>`. `route` verifies the exact host key from `/run/login-gateway/known_hosts/` before forwarding traffic.
3. **Warm attach (<100 ms):** Concurrent terminals, IDE windows, and reconnects read `/run/login-gateway/routes/login-<user>.route`, verify TCP liveness on `<node>:<port>`, and connect immediately without calling `srun` again.
4. **User self-service:** Inside the pod, `login-pod status` shows node/CPU/RAM/time-left, `login-pod restart` cycles the pod to pick up newly granted LDAP/POSIX project groups, and `login-pod stop` terminates the pod cleanly.
5. **Expiry & cleanup:** When `LOGIN_WALLTIME` (default 7 days) expires or `login-pod stop` runs, Slurm reaps the cgroup and `job_container/tmpfs` unmounts `/tmp`, automatically shredding ephemeral SSH keys, runtime sockets, and `/tmp/cluster-status` caches.
