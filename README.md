# slurm-enroot-login

A complete, portable **HPC SSH login gateway & Slurm Enroot container userland**
for clusters that isolate interactive user sessions inside persistent per-user
Slurm jobs via **Pyxis + Enroot** — with **zero site secrets or PII** baked in.

## Architecture Highlights (Single Port 22)

All incoming SSH traffic arrives on standard **Port 22** (no extra firewall
ports required) and is dispatched by the gateway suite in [`gateway/`](gateway/):

1. **Interactive & Remote-IDE Sessions (`login-<user>`):**
   * Authenticates external users via CILogon Device OAuth2 (`pam_oauth2_device` +
     `libnss_shim`) or internal cluster / Open OnDemand Web Shell connections
     via `loginbox-authorized-keys internal %u`.
   * Spawns or reattaches to a persistent per-user Slurm container job
     (`login-<user>`, default `4 CPUs / 4G RAM / 7d`) running an unprivileged
     in-container `sshd` (`container-sshd-entrypoint`) bound strictly to
     internal RFC1918 cluster interfaces + `127.0.0.1` with pinned Ed25519
     host keys and zero files written to `$HOME`.
   * Warm reconnects (`tmux`, VS Code / Cursor Remote-SSH, X11 `-Y`, agent `-A`)
     attach over SSH in `<50 ms` with **zero `srun` steps and zero `slurmctld`
     RPCs**.
2. **Direct Gateway File Transfers (`scp` / `sftp` / `rsync` / `rrsync`):**
   * Intercepted in `switch-user.sh` **before** any Slurm lookup or job spawn,
     validated against shell-metacharacter smuggling, and executed directly on
     the gateway node (sharing `/home`, `/scratch`, `/projects`, `/cache`,
     `/cvmfs`) inside a per-user transient cgroup (`loginbox-xfer.slice`).
3. **Gateway Admin Root Pod (`gateway-admins` / `ccstaff`):**
   * When `ADMIN_POD_ENABLED=1`, members of `GATEWAY_BYPASS_GROUPS` get a
     persistent `admin-<user>` Slurm pod instead of a shell on the gateway.
     The job is submitted as UID 0 with `ENROOT_ALLOW_SUPERUSER`, so the pod
     has no user namespace. It bind-mounts all of `/home`, `/scratch`,
     `/projects`, `/project`, `/cache`, and `/cvmfs`, plus the SSSD sockets,
     and the admin lands as themselves with `NOPASSWD` sudo so they can
     `sudo -i` and `su - <otheruser>`.
   * If the pod cannot be allocated or the attach fails, the session falls
     back to the gateway host (PTY ownership, X11, SSH agent). `ssh host host`
     or `enter-login-job --host` forces that host shell. `ssh host container`
     or `enter-login-job` still opens the unprivileged `login-<user>` pod.
4. **Port-22 Robot Automation (`robot-<user>`):**
   * External public keys on `:22` are accepted **only** for members of
     `ROBOT_GROUP` (`mfa-automation-users`) whose keys pass
     `sss_ssh_authorizedkeys.filter.py` (`restrict` + `from="..."` +
     `command="..."`). Normal users without a matching restricted robot key
     fall straight through to CILogon Device Flow.
   * Robot file transfers run directly on the gateway; non-transfer robot
     commands (`sbatch`, workflow triggers) route into a smaller dedicated
     `robot-<user>` Slurm container job (default `2 CPUs / 1G RAM / 1d`).
5. **Open OnDemand Coexistence:**
   * OOD stays on the gateway VMs using the shared mounts and dynamic OIDC
     provisioning hooks (`gateway/provisioning/`), while OOD's Web Shell app
     connects seamlessly into the user's `login-<user>` container over `:22`.

## Repository Layout

* `Dockerfile`, `login-shell`, `slurm-login-shell`, `container-sshd-entrypoint`,
  `zz-cvmfs.sh` — Public Ubuntu 24.04 login container image (`openssh-server`,
  `xauth`, Slurm client DEBs, Pyxis SPANK plugin, OpenMPI, Lmod/CVMFS hook,
  development & debugging tools).
* `admin-pod/` — Privileged fork of that image (`sudo`, admin sshd entrypoint)
  used by `admin-<user>` jobs. Built with
  `docker build -f admin-pod/Dockerfile .`.
* `gateway/bin/` & `gateway/sbin/` — Host routing & key-filtering scripts
  (`switch-user.sh`, `login-spawn.sh`, `login-stop.sh`, `login-helper.sh`,
  `enter-login-job`, `loginbox-authorized-keys`,
  `sss_ssh_authorizedkeys.filter`, `sss_ssh_authorizedkeys.filter.py`,
  `fake_nss_user.sh`, `fake_nss_group.sh`).
* `gateway/etc/` & `gateway/slurm/` — Sanitized host configs (`loginbox.conf.example`,
  `sshd_config.d/`, `pam.d/`, `sudoers.d/`, `libnss_shim/`, `systemd/`,
  `pyxis.conf.example`, `job_container.conf.example`).
* `gateway/provisioning/` — Sanitized dynamic CILogon + Open OnDemand LDAP,
  TrueNAS ZFS home, Slurm association, and internal SSH key provisioning suite.
* `gateway/containerssh/` — Optional ContainerSSH `:2222` webhook backend.
* `gateway/tests/` — Automated secret/PII scanner (`scan_secrets_pii.py`) and
  unit tests (`test_robot_filter.py`, `test_transfer_classifier.py`).

## Hard Rule: NO SECRETS OR PII

This repository and its Docker Hub image are **public**. Every secret, key,
domain, and site IP is injected at runtime — see [SECRETS.md](SECRETS.md).

## Deploying on a Cluster

```bash
# 1. Import the container image onto shared fast storage (use a versioned filename to avoid NFS ESTALE)
enroot import -o /cache/slurm-enroot-login-v2.sqsh docker://rkhoja/slurm-enroot-login:latest

# 1b. Optional admin root pod image (only needed when ADMIN_POD_ENABLED=1)
enroot import -o /cache/slurm-enroot-login-admin.sqsh docker://rkhoja/slurm-enroot-login:admin

# 2. Install gateway scripts & configuration on login gateway nodes
install -d -m 0755 /etc/loginbox
cp gateway/etc/loginbox/loginbox.conf.example /etc/loginbox/loginbox.conf
install -m 0755 container-sshd-entrypoint /etc/loginbox/container-sshd-entrypoint.sh
install -m 0755 admin-pod/admin-container-sshd-entrypoint /etc/loginbox/admin-container-sshd-entrypoint.sh
install -m 0755 gateway/bin/* /usr/local/bin/
install -m 0755 gateway/sbin/* /usr/local/sbin/
systemctl enable --now loginbox-keygen.service
```

The admin partition must allow root jobs (`DisableRootJobs=NO`). Leave
`ADMIN_POD_ENABLED=0` until that partition and the admin image are in place.
