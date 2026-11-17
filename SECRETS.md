# Runtime Injection & Secret Hygiene Tracking

Everything site-specific or secret that the login gateway and container
userland need, and **how it gets there at runtime** — because this repository
and its Docker Hub image are **public** and must never contain any secrets,
credentials, cluster IPs/domains, or PII.

| Item | Why not baked | Runtime injection mechanism |
|---|---|---|
| Munge key/socket | cluster secret | bind-mount `/run/munge` from the host into the container |
| Slurm config (configless) | cluster config | bind-mount `/etc/slurm` or `/run/slurm/conf`, or bootstrap `sackd` via `_slurmctld._tcp` DNS SRV (`login-shell` & `container-sshd-entrypoint` preserve `SLURM_CONF`) |
| Gateway-to-container SSH proxy keypair | per-cluster auth secret | generated on first boot by `loginbox-keygen.service` at `/etc/loginbox/proxy_id_ed25519` (`0600` root); `.pub` bind-mounted read-only into `/tmp/sshd/authorized_keys` |
| In-container `sshd` host key | per-job identity | generated ephemerally in job tmpfs (`/tmp/sshd/ssh_host_ed25519_key`) by `container-sshd-entrypoint` and pinned via Slurm job `Comment`; `/etc/ssh/ssh_host_*` is stripped in `Dockerfile` |
| User/group resolution | site LDAP/SSSD | gateway SSSD (`getent -s sss`) + `libnss_shim` on the host; Slurm/NSS inside container |
| CVMFS software stack (`/cvmfs`) | host-managed FUSE mounts | bind-mount `/cvmfs` from the execution node |
| Home / scratch / projects | per-user data | `--container-mounts` computed per user by `login-spawn.sh` (own home/scratch + member-group projects only) |
| `/tmp`, `/dev/shm` | per-job isolation | `job_container/tmpfs` (`Shared=true` in `job_container.conf`) |
| Site gateway tunables | per-cluster sizing & groups | `/etc/loginbox/loginbox.conf` (`LOGIN_MEM`, `ROBOT_MEM`, `GATEWAY_BYPASS_GROUPS`, `ROBOT_GROUP`, `INTERNAL_CIDRS`) |
| CILogon OAuth2 / OOD OIDC client secrets | IdP credentials | `/etc/pam_oauth2_device/config.json` and `/etc/ood/config/ood_portal.yml` on gateway node overlays |
| LDAP admin password & TrueNAS API key | storage/IdP secrets | `/etc/loginbox/ldap_admin_password` and `/etc/truenas/api_key` (`0600`) referenced by `/etc/loginbox/provisioning.conf` |
| Gateway SSH host keys & portal TLS certs | host identity | gateway node overlays |

## Enforcement

* `gateway/tests/scan_secrets_pii.py` runs in `.github/workflows/test-image.yml`
  on every push and fails the build on any private key, certificate, inline
  secret/token, Duo/CILogon client ID, hashed OIDC user ID (`clg_<hex>`), or
  site IP/domain leakage.
* `Dockerfile` removes `/etc/ssh/ssh_host_*` during build and CI verifies no
  host keys exist inside the built container image.
