# Admin Root Pod (`admin-<user>`)

By default (`ADMIN_POD_ENABLED="0"`), members of `GATEWAY_BYPASS_GROUPS` (default `sudo,wheel,adm`) bypass `ForceCommand` via `Match Group` in `10-login-gateway.conf` so cluster operators land directly on the gateway host for maintenance.

When `ADMIN_POD_ENABLED="1"`, administrators instead land inside a dedicated **`admin-<user>`** Slurm container pod (`images/admin/Dockerfile`) while still retaining `sudo -i` and `su - <user>` inside the pod.

## How `admin-<user>` Differs from `login-<user>`

| Property | `login-<user>` | `admin-<user>` |
|---|---|---|
| Slurm job owner | `<user>` (unprivileged) | `root` (`ENROOT_ALLOW_SUPERUSER=yes`) |
| User namespace | Unprivileged userns | Host UID mapping (`root` is UID `0` inside pod) |
| Filesystem mounts | Own `/home/<user>`, `/scratch/<user>`, member `/projects/<group>` | Full `/home`, `/scratch`, `/project(s)`, `/var/lib/sss/{pipes,mc}` |
| `sudo` / `su` | Not installed / unprivileged | `sudo` (`NOPASSWD: ALL` for `GATEWAY_BYPASS_GROUPS`) + `libpam-sss` |
| Emergency fallback | `SLURM_DOWN_FALLBACK` (`restricted-shell` or `deny`) | Direct host shell on the gateway so operators are **never** locked out |

## Required Slurm Partition Settings

Because `admin-<user>` runs as UID `0`, `ADMIN_PARTITION` must reside on trusted administrative/login nodes where `DisableRootJobs=NO` is acceptable. Never place `ADMIN_PARTITION` on general multi-tenant compute nodes if site policy prohibits root Slurm jobs there.

Remove the `Match Group adm,sudo,wheel -> ForceCommand none` block in `/etc/ssh/sshd_config.d/10-login-gateway.conf` when enabling `ADMIN_POD_ENABLED="1"` so admin SSH sessions enter `dispatch -> route` (which automatically detects `GATEWAY_BYPASS_GROUPS` and routes them to `admin-<user>`).
