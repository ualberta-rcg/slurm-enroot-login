# Robot / MFA Automation Gateway Standard

`slurm-login-pods` implements the [Digital Research Alliance of Canada MFA Automation Standard](https://docs.alliancecan.ca/wiki/Automation_in_the_context_of_multifactor_authentication).

## Dedicated `robot.<cluster>` Mode (`ROBOT_MODE="dedicated"`)

On a dedicated automation node or secondary IP (`robot.<cluster>`):

1. **`sshd` hardening (`10-robot-gateway.conf`):**
   - `AuthorizedKeysFile /dev/null` — `~/.ssh/authorized_keys` in `$HOME` is completely ignored (`ALLOW_HOME_ROBOT_KEYS="0"`).
   - `AuthorizedKeysCommand /usr/local/sbin/sss_ssh_authorizedkeys.filter --rewrite-dispatch %u` — keys come solely from CCDB/LDAP via SSSD.
   - `AuthenticationMethods publickey` — no keyboard-interactive / Duo prompt.
   - `PermitTTY no`, `DisableForwarding yes`, `X11Forwarding no`, `AllowAgentForwarding no`, `AllowTcpForwarding no`.
2. **Group gate:** Only members of `ROBOT_GROUP` (default `mfa-automation-users`) receive keys from the filter; all other users receive zero keys.
3. **Key option validation (`sss_ssh_authorizedkeys.filter.py`):**
   Every SSH public key line is parsed strictly (handling escaped quotes inside `command="..."`) and rejected unless **all** of the following hold:
   - `restrict` (or explicit `no-pty,no-port-forwarding,no-agent-forwarding,no-X11-forwarding,no-user-rc`) is present.
   - `command="<non-empty>"` is present.
   - `from="<pattern-list>"` is present, contains no negated (`!`) patterns, contains no hostnames (unless `ALLOW_FROM_HOSTNAMES=1`), and **every** entry is a globally routable public IP address or prefix:
     - **IPv4:** single IP, CIDR `/24`..`/32`, or wildcard fixing at least the first three octets (`198.51.100.*`). Broad wildcards (`*`, `198.51.*`), RFC1918 (`10/8`, `172.16/12`, `192.168/16`), loopback (`127/8`), link-local (`169.254/16`), and CGNAT (`100.64/10`) are rejected.
     - **IPv6:** single IP, CIDR `/64`..`/128`, or wildcard with at least 4 fixed leading hextets. Loopback, link-local (`fe80::/10`), ULA (`fc00::/7`), and multicast are rejected.

## Why `command=` Rewriting Instead of `ForceCommand`

In OpenSSH, `sshd_config` `ForceCommand` **overrides** a key's `command="..."` option, discarding the exact forced command stored in CCDB/LDAP!

To preserve the key's `command=` while still confining execution:
- `robot.<cluster>` does **not** set `ForceCommand` in `sshd_config`.
- Instead, `sss_ssh_authorizedkeys.filter --rewrite-dispatch` rewrites each validated key's `command="<orig>"` to:
  ```text
  command="/usr/local/libexec/login-gateway/dispatch --robot --orig-cmd '<base64(orig)>'"
  ```
- When `sshd` authenticates the key, `dispatch` decodes `<orig>`:
  - If `<orig>` + `SSH_ORIGINAL_COMMAND` is a valid file transfer (including CVMFS `transfer_commands.sh` or `rrsync`), it runs directly on the gateway inside `login-gateway-xfer.slice`.
  - Otherwise, `dispatch` invokes `sudo -n route --mode robot`, spawning a small `robot-<user>` pod (`2` CPUs, `1G` RAM, `02:00:00` walltime, **no MOTD**, **no AI guardrails**) and executing `<orig>` with `SSH_ORIGINAL_COMMAND` exported.

## Shared Port-22 Mode (`ROBOT_MODE="port22"`)

Smaller clusters without a separate `robot.<cluster>` IP can set `ROBOT_MODE="port22"`. In this mode, `login-gateway-authorized-keys` injects `environment="LOGIN_KEY_TYPE=robot"` + `--rewrite-dispatch` onto valid automation keys on port 22, and a PAM rule skips Duo only when an automation key authenticated the session.

## SSSD / CCDB Requirement (Non-CILogon Sites Only)

Alliance MFA automation (`robot.<cluster>`) relies on SSH public keys stored in **CCDB / LDAP and resolved directly via SSSD** (`sss_ssh_authorizedkeys`). Sites that authenticate SSH sessions through a synthetic OIDC / CILogon NSS shim account (`SHIM_USERS` + `/etc/login-gateway/hooks/identity`) **must set `ROBOT_ENABLED="0"`** in `/etc/login-gateway/login-gateway.conf`; `route` explicitly refuses `--robot` sessions whenever the caller resolved via `SHIM_USERS`.
