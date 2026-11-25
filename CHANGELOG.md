# Changelog

All notable changes to this project are documented in this file.

## [2.1.0] - 2026-11-25 (`26.05.6-2`)

### Added
- **Rootless user-pod UTS hostnames (`50-login-pod-hostname.sh`):** Enroot hook sets `<cluster>-login-<user>` inside unprivileged `login-<user>` pods (`hostname`, `/etc/hostname`, `/etc/hosts` `127.0.1.1`) while guarding host user/UTS namespaces and skipping ordinary batch container jobs.
- **All 7 AI coding agent CLIs in user & admin images:** Baked Node.js 22 LTS + `claude`, `codex`, `opencode`, `gemini`, `pi`, `cursor-agent`, and `agy` (pinned/checksummed, self-updaters disabled for read-only SquashFS) plus `agent-guardrails {link,status,list-community,install-community}` and 10 opt-in research skills (`drac-agent-skills`). Entrypoints link skills/instructions at pod startup so VS Code Remote-SSH, Open OnDemand, and non-interactive `ssh host cmd` sessions are covered alongside interactive logins.
- **Unrestricted `admin-<user>` AI & sysadmin environment:** Admin image omits user-pod command deny/ask restrictions (`ADMIN_AGENT_GUARDRAILS="0"` default) while preserving Alliance skills, `/etc/agents/site.md`, and status tooling, and adds K8s (`kubectl`, `helm`, `k9s`, `stern`), Ansible, `clush`, IPMI/BMC, NVMe/SMART, LDAP/SSSD/Munge, network diagnostics (`nmap` moved from user image to admin image, `tcpdump`, `iperf3`, `nft`, `conntrack`), storage/backup (`restic`, `s5cmd`, `aws`), DB clients, `tofu`, `openstack`, `gh`, `glab`, `bpftrace`, `perf`, `atop`, and `sosreport`.
- **Developer & HPC user utilities:** Added `uv`/`uvx`, `gh`, `globus-cli`, `sqlite3`, `hdf5-tools`, `netcdf-bin`, `x11-apps`, `direnv`, `shellcheck`, `tig`, `mc`, `inotify-tools`, `hyperfine`, `entr`, `time`, and Slurm bash completion.
- **Pass-in announcements & non-interactive site status `PATH`:** `cluster-status` supports `--announce`, `CLUSTER_STATUS_ANNOUNCE`, single files or `announce.d/*.txt` drop-ins with `expires: YYYY-MM-DD HH:MM`, ANSI/control stripping, `/etc/nologin` banners, gateway `STATUS_ANNOUNCE_PATH` read-only pod mounts, `cluster-status-announce {set,append,clear,show}`, and `/etc/cluster-status/bin` on `PATH` across non-interactive and interactive shells.
- **Gateway hardening & scheduling polish:** `GatewayPorts no` in pod `sshd`, `ProtectSystem=strict` + `InaccessiblePaths` sandbox for `route` file transfers, `logger -t login-gateway` structured audit logs, `SHIM_USERS` robot refusal, `systemd-run --collect`, `--oversubscribe` + local-node capacity preference with fallback in `spawn`, and `deploy/warewulf/import-image.sh` (refuses to overwrite mounted `.sqsh` files).

## [2.0.0] - 2026-11-24

### Added
- **Generic Alliance SSH entrypoint (`login-gateway/libexec/dispatch` + `route`):** `ForceCommand` runs `dispatch` as the authenticated user, executing `scp`, `sftp`, `rsync --server`, `rrsync`, and Alliance CVMFS `transfer_commands.sh` wrappers directly on the gateway inside `login-gateway-xfer.slice` with zero Slurm jobs, while routing interactive shells, IDEs, and remote commands via `sudo -n route` (`SUDO_USER`-verified).
- **Site hook interface (`/etc/login-gateway/hooks/{identity,provision,motd}`):** Clean extension points for sites with synthetic OIDC/CILogon accounts or first-login storage provisioning, keeping all site-specific logic outside the public repository.
- **Alliance MFA automation (`robot.<cluster>`) standard:** Dedicated `robot.conf.example` (`AuthorizedKeysFile /dev/null`, `PermitTTY no`, `DisableForwarding yes`) and hardened `sss_ssh_authorizedkeys.filter` enforcing `mfa-automation-users` group membership, `restrict`, `command=`, and public-only `from=` CIDRs (`/24` IPv4, `/64` IPv6).
- **Pod hardening & Alliance login-node parity:**
  - Containment sentinel (`/etc/slurm-login-pods-release` + mount namespace check) preventing uncontained host execution if Pyxis fails.
  - Per-user UTS pod hostnames (`--container-unshare=uts`, `POD_HOSTNAME_TEMPLATE`).
  - Private per-pod `XDG_RUNTIME_DIR` (`/tmp/run-$UID`, `0700`).
  - User `login-pod {status|restart|stop}`, `sq`, `seff`, and `diskusage_report` commands plus `/etc/profile.d/50-alliance-env.sh` (`$SCRATCH`, `$PROJECT`, `$CC_CLUSTER`, `~/scratch` & `~/projects` symlinks) and `/usr/libexec/openssh/sftp-server` compatibility symlink.
  - Restricted cgroup-bounded gateway fallback shell when `slurmctld` is unreachable (`SLURM_DOWN_FALLBACK="restricted-shell"`).
- **Generic `cluster-status` banner (`status/`):** Pod-aware port of `vulcan-status` that hides `login-*`/`robot-*`/`admin-*` infrastructure jobs, displays a `Login pod` status line, stays silent during file transfers and robot sessions, and caches inside pod-private `/tmp/cluster-status` via a jittered background loop.
- **AI `agent-guardrails` (`agent-guardrails/`):** Vendored system-wide HPC guardrails and 5 core Alliance skills (`alliance-slurm`, `alliance-cvmfs`, `alliance-docs`, `alliance-arbutus`, `alliance-gitlab`) from `drac-agent-skills` with pod-aware `AGENTS.md`/`CLAUDE.md`, optional `/etc/agents/site.md` include, and automatic disablement in `robot-*` pods.
- **Deployment tooling & documentation (`deploy/`, `docs/`):** Secret-free Warewulf 4 overlay renderer (`deploy/warewulf/render-overlays.sh`), standalone installer (`deploy/standalone/install.sh`), Ansible node playbooks (`deploy/ansible/`), and 11 operational guides under `docs/`.

### Changed
- Restructured repository into `images/{user,admin}`, `login-gateway/`, `slurm/`, `status/`, `agent-guardrails/`, `deploy/`, `docs/`, and `tests/` (with backward-compatibility symlinks and `/etc/loginbox` config fallback preserved).
- Removed site-specific CILogon/NSS shim, storage provisioning, and ContainerSSH webhook experiments from the public repository.
