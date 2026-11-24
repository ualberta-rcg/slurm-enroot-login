# Runtime Injection & Secret Hygiene Policy

This repository and its published container images (`user` and `admin`) are **100% public and cluster-agnostic**. They must never contain secrets, private keys, API tokens, internal IP addresses, hashed OIDC user identifiers, or site-specific hostnames.

## How site state & secrets enter at runtime

| Item | Why excluded from repo | Runtime injection mechanism |
|---|---|---|
| Munge key / socket | Cluster authentication secret | Bind-mounted from host `/run/munge` into pods |
| Slurm configuration | Site topology | Bind-mounted from `/etc/slurm` or `/run/slurm/conf` (or DNS SRV configless Slurm) |
| Gateway -> pod SSH proxy keypair | Per-cluster internal auth secret | Generated on first gateway boot by `login-gateway-keygen.service` at `/etc/login-gateway/proxy_id_ed25519` (`0600` root); `.pub` copied into pod `/tmp/sshd/authorized_keys` |
| In-pod `sshd` host key | Per-job ephemeral identity | Generated in per-job tmpfs (`/tmp/sshd/ssh_host_ed25519_key`) by `container-sshd-entrypoint`; SHA256 fingerprint published via Slurm job `Comment` and verified by `SSHFP` / `KnownHosts` pinning in `route`. `/etc/ssh/ssh_host_*` is deleted at image build time |
| User & group directory | Site LDAP / SSSD | Host SSSD (`getent` / `sss_ssh_authorizedkeys`); `/var/lib/sss/{pipes,mc}` mounted in `admin-<user>` pods |
| Duo 2FA integration keys | MFA secret | Host `/etc/duo/pam_duo.conf` (`0600` root) in site overlay |
| Custom IdP / provisioning credentials | Site-specific secrets | Kept strictly in private site overlays (`/etc/login-gateway/hooks/{identity,provision}`) |
| CVMFS software tree (`/cvmfs`) | Host FUSE mounts | Bind-mounted from the execution node |
| `/home`, `/scratch`, `/project(s)` | Per-user research data | Scoped per-user `--container-mounts` computed by `spawn` (user's own home/scratch + member project groups only) |
| Status branding & announcements | Site URLs & notices | `/etc/cluster-status/{motd.conf,logo.txt,links.txt,announce.txt}` in site overlay (mounted `:ro` into non-robot pods) |
| AI agent site facts & LLM API keys | Site GPU/partition facts; user/site keys | `/etc/agents/site.md` (`:ro` bind mount) for cluster facts; no API keys are ever shipped here |

## Automated CI Enforcement

- [`tests/scan_secrets_pii.py`](./tests/scan_secrets_pii.py) runs in `.github/workflows/test-image.yml` on every branch push and pull request. It fails CI on private keys, X.509 certificates, inline tokens/passwords, Duo/OIDC client secrets, `clg_<hex>` identifiers, RFC1918 site leaks outside test fixtures, or site-internal domains.
- Both `images/user/Dockerfile` and `images/admin/Dockerfile` strip `/etc/ssh/ssh_host_*` during build and write `/etc/slurm-login-pods-release` so pods refuse to start if Pyxis fails to enter the container rootfs.

## Admin Root Pod Trust Boundary (`admin-<user>`)

`admin-<user>` is an opt-in (`ADMIN_POD_ENABLED="1"`) privileged Slurm job submitted as UID `0` with `ENROOT_ALLOW_SUPERUSER=yes` for members of `GATEWAY_BYPASS_GROUPS`. Unlike unprivileged `login-<user>` pods, root inside `admin-<user>` is real UID `0` inside the pod's mount/UTS namespace and mounts top-level `/home`, `/scratch`, and `/project(s)` so administrators can `sudo -i` and `su - <user>` without polluting the SSH gateway host. Keep `ADMIN_POD_ENABLED="0"` unless `ADMIN_PARTITION` is dedicated to trusted administrative nodes (`DisableRootJobs=NO`).
