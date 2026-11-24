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
| Home / scratch / projects | per-user data | `--container-mounts` computed per user by `login-spawn.sh` (own home/scratch + member-group projects only). Admin pods instead mount the top-level shared filesystems. |
| Admin root pod | privileged session for `GATEWAY_BYPASS_GROUPS` | `/etc/loginbox/loginbox.conf` (`ADMIN_POD_ENABLED`, `ADMIN_IMAGE_PATH`, `ADMIN_PARTITION`, `ADMIN_CPUS`, `ADMIN_MEM`, `ADMIN_WALLTIME`). The pod bind-mounts `/var/lib/sss/pipes` and `/var/lib/sss/mc` so `libnss-sss` / `libpam-sss` can resolve every user. The image tag is built from `admin-pod/Dockerfile`. No site secrets are baked into it. |
| `/tmp`, `/dev/shm` | per-job isolation | `job_container/tmpfs` (`Shared=true` in `job_container.conf`) |
| Site gateway tunables | per-cluster sizing & groups | `/etc/loginbox/loginbox.conf` (`LOGIN_MEM`, `ROBOT_MEM`, `GATEWAY_BYPASS_GROUPS`, `ROBOT_GROUP`, `INTERNAL_CIDRS`, `ADMIN_POD_ENABLED`) |
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

## Admin root pod trust boundary

`admin-<user>` is not an unprivileged login container. It is a Slurm job run
as UID 0 with `ENROOT_ALLOW_SUPERUSER=yes`, so Pyxis/Enroot skip the user
namespace. Inside the pod, root is real, every cluster uid/gid is real, and
top-level `/home` (plus scratch, projects, cache, and CVMFS) is bind-mounted.
`sudo` and `su` therefore work across `root_squash` NFS homes once the
session has changed to that user's uid.

That is root-equivalent access to user data on the node that runs the pod.
Keep `ADMIN_POD_ENABLED` off until `ADMIN_PARTITION` is a partition that
allows root jobs (`DisableRootJobs=NO`) and whose nodes are an acceptable
place for that access. Membership of `GATEWAY_BYPASS_GROUPS` is the only
authorization check. If the pod cannot start, the gateway falls back to the
host shell so admins are not locked out.
