# Troubleshooting Field Guide

## 1. Pod Refuses to Start with `CONTAINMENT FAILURE` (Exit 78)

**Symptom:** Job log (`/run/login-gateway/logs/login-<user>.log`) shows:
`FATAL: /etc/slurm-login-pods-release missing on <node> — refusing to start uncontained sshd on host.`

**Cause:** Pyxis was not loaded on the execution node (`plugstack.conf` missing `spank_pyxis.so`), or `srun` dropped `--container-image` and attempted to run the entrypoint directly on the bare host OS.

**Fix:** Verify `/etc/slurm/plugstack.conf` includes `/etc/slurm/plugstack.d/*` on every node in the `login` partition and `srun --help | grep container-image` succeeds.

---

## 2. Pod Killed by OOM During Heavy File Reads (Page Cache Accounting)

**Symptom:** Running `tar`, `git clone`, or `rsync` inside a `login-<user>` pod triggers a cgroup OOM event even though RSS is small.

**Cause:** Linux `cgroup/v2` charges buffered filesystem page cache against `memory.max` (`LOGIN_MEM`).

**Fix:**
- Perform bulk transfers via `scp`/`sftp`/`rsync` from outside the cluster so they hit the gateway fast-path (`login-gateway-xfer.slice`) instead of the login pod.
- Increase `LOGIN_MEM` (e.g. `4G` -> `8G`) in `/etc/login-gateway/login-gateway.conf` if researchers routinely unpack multi-gigabyte archives interactively.

---

## 3. Nested `srun` / `sbatch` Inside a Pod Fails with Pyxis SPANK Variable Leak

**Symptom:** Running `sbatch` or `srun` *from inside* `login-<user>` fails with `pyxis: container image already set` or unexpected mount errors.

**Cause:** Inherited `SLURM_*` or `SPANK_PYXIS_*` environment variables from the outer `login-<user>` job leaked into the user's shell.

**Fix:** `images/user/login-shell` and `container-sshd-entrypoint` scrub `SLURM_*`, `SBATCH_*`, `SRUN_*`, `SPANK_*`, `PMI_*`, and `ENROOT_*` (preserving only `SLURM_CONF` and saving the pod's own job metadata under `LOGIN_POD_*`). Ensure users invoke `/usr/local/bin/login-shell` or connect through the pod's `sshd` rather than `srun --overlap` without `enter-login-job`.

---

## 4. `ESTALE` (Stale File Handle) on NFS `/home` or `/projects` Inside Long-Lived Pods

**Symptom:** After storage server failover or directory recreation, `cd ~` inside a days-old pod returns `Stale file handle`.

**Fix:** Have the user run `login-pod restart` (or as root on the gateway: `/usr/local/libexec/login-gateway/stop <user> login`) to tear down the pod's mount namespace and spawn a fresh pod with clean NFS mounts.

---

## 5. Robot Automation Key Rejected Despite Valid `from=` IPv4 Rule

**Symptom:** `ssh robot.cluster` prompts for publickey failure even though the client IPv4 is listed in CCDB `from="198.51.100.0/24"`.

**Cause:** Either:
1. Dual-stack DNS caused the client to connect over **IPv6** while `from=` only listed an IPv4 `/24` (check `journalctl -u ssh` on `robot.<cluster>` for the source IP), **or**
2. The user is not yet in the `mfa-automation-users` LDAP group (`id -Gn <user>`), or SSSD cached stale `sshPublicKey` attributes (`sss_cache -u <user>`).

**Fix:** Test the exact filtered output as root on the gateway:
```bash
/usr/local/sbin/sss_ssh_authorizedkeys.filter --rewrite-dispatch <user>
```
Rejected keys log an explicit reason (`missing restrict`, `prefix /16 broader than /24`, `not in group mfa-automation-users`, etc.) to syslog (`auth.notice`).
