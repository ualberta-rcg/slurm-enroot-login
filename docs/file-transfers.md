# Gateway File-Transfer Fast-Path

## Why Transfers Stay on the Gateway

Routing `scp`, `sftp`, or `rsync` into a Slurm pod has three operational downsides:
1. **Cold-start latency:** Automated scripts and short `scp` transfers should never wait 2–3 seconds for Pyxis/Enroot to mount a SquashFS image and spawn `sshd`.
2. **Scheduler noise:** Cron-driven `rsync` jobs would churn Slurm job accounting (`login-*` / `robot-*`).
3. **Banner cleanliness:** Non-interactive transfer streams are fatal to any stray stdout text; running the transfer binary directly via `exec` guarantees a clean byte stream.

Instead, `dispatch` sources `classify-transfer` **as the unprivileged authenticated user** and executes validated transfer servers directly on the gateway inside `login-gateway-xfer.slice` (CPU- and RAM-capped via systemd).

## Accepted Transfer Commands

`classify-transfer` rejects any command containing shell metacharacters (`;`, `&`, `|`, `` ` ``, `$`, `<`, `>`, `(`, `)`, newlines) and accepts **only** exact server-mode invocations:

1. **Legacy `scp` (`scp -O`):** `scp [-r -p -d -v -q] (-t|-f) [--] <target>`
2. **SFTP & modern OpenSSH 9+ `scp`:**
   - `/usr/lib/openssh/sftp-server` (Debian/Ubuntu path)
   - `/usr/libexec/openssh/sftp-server` (RHEL/Alliance path — symlinked to `/usr/lib/openssh/sftp-server` on Ubuntu gateways and images)
   - `internal-sftp` (automatically mapped to the host `sftp-server` binary)
3. **`rsync` server mode:** `rsync --server [-flags] . [<path>]` (explicitly blocking `--daemon` and `--config`)
4. **Restricted `rsync` (`rrsync`):** `rrsync [-ro|-wo|-munge|-no-del|-no-lock|-no-overwrite] <directory>`
5. **Alliance CVMFS `allowed_commands` wrappers:**
   - `/cvmfs/soft.computecanada.ca/custom/bin/computecanada/allowed_commands/transfer_commands.sh`
   - `/cvmfs/soft.computecanada.ca/custom/bin/computecanada/allowed_commands/allowed_commands.sh` (only when `SSH_ORIGINAL_COMMAND` is itself a valid transfer; non-transfer commands like `sbatch` or `git` under `allowed_commands.sh` route into a `robot-<user>` pod!)

### Ubuntu / RHEL `sftp-server` Normalization

Alliance's upstream CVMFS `transfer_commands.sh` checks specifically for `/usr/libexec/openssh/sftp-server`. On Ubuntu/Debian systems, OpenSSH clients invoking SFTP or modern `scp` request `/usr/lib/openssh/sftp-server` (from `Subsystem sftp`). `classify-transfer` normalizes `SSH_ORIGINAL_COMMAND` to `/usr/libexec/openssh/sftp-server` before `exec`-ing `transfer_commands.sh`, and `slurm-login-pods` installs `/usr/libexec/openssh/sftp-server -> /usr/lib/openssh/sftp-server` on both the gateway and container images so transfers succeed seamlessly across RHEL and Ubuntu clients.
