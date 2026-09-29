# Runtime injection tracking

Everything site-specific or secret that the login environment needs, and
**how it gets there at runtime** — because this image is public and must
never contain any of it. Add a row whenever a new runtime dependency is
introduced.

| Item | Why not baked | Injection mechanism |
|---|---|---|
| Munge key/socket | cluster secret | bind-mount `/run/munge` (read-only) from the host into the container |
| Slurm config (configless) | cluster config | bind-mount host's config cache `/run/slurm/conf`, or rely on `_slurmctld._tcp` DNS SRV — entrypoint preserves `SLURM_CONF` |
| User/group resolution | site LDAP/SSSD | bind-mount `/etc/sssd` (and sssd socket) or use `nss_slurm` from the job environment |
| Home / scratch / projects | per-user data | `--container-mounts` computed per user by the gateway dispatcher (own home/scratch + member-group projects only) |
| `/tmp`, `/dev/shm` | per-job isolation | `job_container/tmpfs` (Slurm-side, not an image concern) |
| Site motd / banner | per-cluster text | overlay or bind-mount at dispatch |
| PAM / Duo / 2FA | gateway concern only — the container has no sshd | lives on the gateway node image, not here |
| OOD portal, portal TLS | gateway concern only | gateway node |
| LDAP admin password, TrueNAS API key, SSH host keys | cluster secrets (current Eureka: login overlay) | gateway node overlays; must never enter this repo |
| Cluster name / ctld hosts | per-cluster | DNS SRV record or bind-mounted config cache |
| License keys (compilers, etc.) | per-site licenses | mount license env/server config at runtime |

## Enforcement

* `test-image.yml` runs a pattern scan (private keys, passwords, tokens)
  over the repo and fails on any hit.
* Rule of thumb for contributors: if a value would let someone authenticate,
  decrypt, or reach a private cluster resource — it belongs on this page's
  right-hand column, not in a commit.
