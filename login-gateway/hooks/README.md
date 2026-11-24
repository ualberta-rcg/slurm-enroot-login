# Site Hooks (`/etc/login-gateway/hooks/`)

`slurm-login-pods` assumes a standard Digital Research Alliance of Canada cluster
out of the box (SSSD/LDAP users, CCDB SSH keys, and Duo 2FA). Sites with custom
identity layers or on-the-fly account provisioning can drop root-owned (`0:0`,
mode `0755` or `0700`, never group/world-writable) executables into
`/etc/login-gateway/hooks/` without modifying repository scripts.

All hooks are optional; the directory is empty in a standard deployment.

## Supported Hooks

### 1. `/etc/login-gateway/hooks/identity`
Used **only** when `SUDO_USER` is listed in `SHIM_USERS` in
`/etc/login-gateway/login-gateway.conf` (for example, clusters that map dynamic
OIDC/CILogon logins through an unprivileged `libnss_shim` account).

- **Invoked by:** `/usr/local/libexec/login-gateway/route` (as `root`)
- **Environment:** inherits `SUDO_USER`, `SUDO_UID`, and `LOGIN_GATEWAY_SHIM_HINT`
  (if set by a site shim shell)
- **Expected stdout:** single line containing the resolved POSIX username
  (`[a-zA-Z0-9._-]+`), exit `0`. Non-zero exit or empty output aborts the login.
- **Security invariant:** On standard clusters (`SHIM_USERS=""`), this hook is
  never called and `route` trusts `SUDO_USER` exclusively.

### 2. `/etc/login-gateway/hooks/provision`
Optional idempotent hook invoked by `route` as `root` after resolving
`TARGET_USER` and before fast-path transfer execution or pod spawning.

- **Arguments:** `$1` = `TARGET_USER`, `$2` = `SESSION_MODE` (`login`|`robot`|`admin`|`transfer`)
- **Use case:** Creating missing ZFS/NFS home datasets, Slurm associations, or
  project symlinks on clusters that provision accounts at first login.

### 3. `/etc/login-gateway/hooks/motd`
Optional executable invoked on interactive logins before attaching to the pod
(when `~/.hushlogin` is absent). If absent, `/etc/motd` on the gateway is not
printed when `STATUS_ENABLED=1` inside the pod (avoiding duplicate banners), or
printed once when `STATUS_ENABLED=0`.
