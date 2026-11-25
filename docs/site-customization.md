# Site Customization Guide

`slurm-login-pods` is designed so **zero site-specific code or branding ever needs to be forked in git**. Customize your deployment through four clean configuration surfaces in your site overlay or `/etc`:

## 1. Gateway Configuration (`/etc/login-gateway/login-gateway.conf`)

Copy [`login-gateway/etc/login-gateway/login-gateway.conf.example`](../login-gateway/etc/login-gateway/login-gateway.conf.example) to `/etc/login-gateway/login-gateway.conf` (`0644`, `root:root`) and set:
- `CLUSTER_NAME` (e.g. `"narval"`, `"rorqual"`, `"vulcan"`)
- `IMAGE_PATH` (e.g. `"/cache/slurm-login-pods-2026.11.sqsh"`)
- `LOGIN_CPUS`, `LOGIN_MEM`, `LOGIN_WALLTIME`
- `ROBOT_MODE` (`"dedicated"` for `robot.<cluster>`, `"port22"` for single-IP clusters)

## 2. Site Hooks (`/etc/login-gateway/hooks/`)

All hooks are optional executables (`0755`, `root:root`, never group/world-writable). See [`login-gateway/hooks/README.md`](../login-gateway/hooks/README.md):

- **`/etc/login-gateway/hooks/identity`:**
  Used by clusters where SSH authenticates a synthetic gateway user (such as an OIDC/CILogon device-flow account listed in `SHIM_USERS="cilogon"`) and maps the session to a real POSIX username printed on stdout. Ignored for normal SSSD users.
- **`/etc/login-gateway/hooks/provision`:**
  Invoked as `provision <user> <mode>` before spawning a pod. Ideal for just-in-time ZFS/Lustre/NFS home or scratch dataset creation on first login.
- **`/etc/login-gateway/hooks/motd`:**
  Invoked on interactive login before routing into the pod (e.g. site policy acceptance notices).

## 3. Status Banner Branding (`/etc/cluster-status/`)

`spawn` bind-mounts `/etc/cluster-status` read-only into every non-robot pod, so editing `/etc/cluster-status/` on the gateway/host immediately updates the login banner inside pods without rebuilding the container image:

- `/etc/cluster-status/motd.conf`:
  ```bash
  CLUSTER_NAME="mycluster"
  STATUS_CMD_NAME="mycluster-status"   # creates shell alias + updates banner footer
  SITE_TITLE="My University Research Computing · Digital Research Alliance of Canada"
  LOGO_FILE="/etc/cluster-status/logo.txt"
  LINKS_FILE="/etc/cluster-status/links.txt"
  ```
- `/etc/cluster-status/logo.txt`: Plain-text ASCII art logo.
- `/etc/cluster-status/links.txt`: `Label:|https://url` lines (`Support:`, `Documentation:`, `Portal:`, `Open OnDemand:`).
- `/etc/cluster-status/bin/<mycluster>-status`: Symlink to `/usr/local/bin/cluster-status`. `/etc/cluster-status/bin` is placed on `PATH` in login shells, pod `sshd` `SetEnv`, and `login-shell`, so the site status command works in both interactive terminals and non-interactive AI agent tool calls.
- **Pass-in announcements (`ANNOUNCE` / `STATUS_ANNOUNCE_PATH`):** Point `STATUS_ANNOUNCE_PATH` in `login-gateway.conf` (and `ANNOUNCE` in `motd.conf`) to a shared file or drop-in directory (e.g. `/cache/cluster-status/announce.d`). `spawn` bind-mounts it read-only into every `login-*` and `admin-*` pod, and operators can post/expire/clear notices live without rebuilding overlays using `cluster-status-announce set --expires "YYYY-MM-DD HH:MM" "..."` or `cluster-status-announce clear`.

## 4. AI Agent Cluster Notes (`/etc/agents/site.md`)

Drop a concise Markdown file at `/etc/agents/site.md` on the host/overlay. `spawn` bind-mounts `/etc/agents/site.md` read-only into `login-<user>` pods, and the baked-in `AGENTS.md`/`CLAUDE.md` instructs Claude Code, Codex, OpenCode, Gemini CLI, Pi, and Cursor to read `/etc/agents/site.md` before submitting Slurm jobs (partition names, `--gres=gpu:<model>:N`, MIG shard syntax, default walltimes, and local portal URLs).

To customize Claude Code's startup `companyAnnouncements` header on the host, create `/etc/claude-code/site-banner.env` (`BANNER_TITLE`, `BANNER_SUBTITLE`, `BANNER_FOOTER`) and run `/etc/claude-code/update-motd.sh`.
