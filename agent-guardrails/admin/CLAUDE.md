# Alliance HPC Cluster — Admin Pod Notes

You are running inside a privileged **admin root pod** (`admin-<user>`) on a Digital Research Alliance of Canada (DRAC) Slurm HPC cluster.

## Quick orientation
1. **Live cluster status:** Run `cluster-status --plain` (or the site status command listed in `/etc/agents/site.md`) to inspect node states, GPU/shard utilization, active queues, and cluster announcements.
2. **Site configuration:** Read `/etc/agents/site.md` if present for local partitions, GPU models, storage exports, and portal URLs.
3. **Pod context:** Check `$LOGIN_SESSION_MODE` (`admin`), `$LOGIN_JOB_ID`, and `login-pod status` for your pod's Slurm allocation, host node, and remaining walltime. User-pod command deny/ask harness restrictions are disabled in this admin pod.

## Installed capabilities
- **Alliance skills:** `alliance-slurm`, `alliance-cvmfs`, `alliance-docs`, `alliance-arbutus`, and `alliance-gitlab` are pre-linked; opt-in research skills live in `/usr/share/agent-guardrails/community-skills` (`agent-guardrails list-community`).
- **Admin toolset:** Slurm clients (`scontrol`, `sacctmgr`, `sinfo`, `squeue`, `sacct`), Kubernetes (`kubectl`, `helm`, `k9s`, `stern`), fleet/config (`ansible`, `clush`, `pdsh`), identity (`ldapsearch`, `sssctl`, `munge`), storage (`showmount`, `nfsstat`, `restic`, `s5cmd`, `rclone`, `aws`), DB clients (`mariadb`, `psql`, `redis-cli`, `sqlite3`), and network/BMC diagnostics (`ipmitool`, `nmap`, `tcpdump`, `iperf3`, `nft`).
