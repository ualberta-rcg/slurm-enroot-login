# Connection Flows

Every client workflow uses standard OpenSSH on port 22 without requiring client-side `ProxyCommand` wrappers.

## 1. Interactive Shell (`ssh user@login.cluster`)

1. `sshd` authenticates the user via CCDB/SSSD SSH public key + Duo 2FA (`pam_duo.so`).
2. `ForceCommand /usr/local/libexec/login-gateway/dispatch` runs as `user` with `SSH_ORIGINAL_COMMAND=""`.
3. `dispatch` invokes `sudo -n /usr/local/libexec/login-gateway/route --mode login`.
4. `route` ensures `login-<user>` is running, allocates a PTY (`-tt`), forwards `TERM`/`LANG`/`LC_*`, and connects over the internal network to `<pod_node>:<pod_port>` using `/etc/login-gateway/proxy_id_ed25519`.
5. Inside the pod, `sshd` launches the user's login shell, sourcing `/etc/profile.d/50-alliance-env.sh`, `/etc/profile.d/ai-agent-skills.sh`, `/etc/profile.d/zz-cvmfs.sh`, and `/etc/profile.d/zz-cluster-status.sh`.

## 2. Non-Interactive SSH Command (`ssh user@login.cluster 'squeue -u $USER'`)

1. `SSH_ORIGINAL_COMMAND` is `'squeue -u $USER'` (not a file-transfer server command).
2. `dispatch` passes `--cmd "$SSH_ORIGINAL_COMMAND"` to `sudo -n route`.
3. `route` connects to `login-<user>` without forcing a PTY (`-T` unless `SSH_TTY` was requested) and executes `/bin/bash -lc 'squeue -u $USER'` inside the pod, preserving stdout, stderr, and exit status cleanly.

## 3. VS Code, Cursor & JetBrains Remote-SSH

Modern Remote-SSH IDEs either:
- Open an interactive/non-interactive bootstrap script over SSH (`bash` reading a script on stdin) and establish dynamic TCP port forwarding (`-L` / `direct-tcpip`), **or**
- Configure a jump/stdio tunnel (`ssh -W host:port`).

When the gateway `sshd` handles port forwarding or when the client sends `SSH_ORIGINAL_COMMAND` for the IDE server bootstrap, `route` proxies the bootstrap shell directly into `login-<user>`. Because `login-<user>` persists for `LOGIN_WALLTIME` (`7-00:00:00`) with a real `sshd` and private `/tmp/run-$UID` (`XDG_RUNTIME_DIR`), the IDE's background server (`~/.vscode-server`, `~/.cursor-server`) stays inside the pod's 4-CPU / 4-GB cgroup rather than running on the gateway host.

## 4. X11 (`ssh -X` / `ssh -Y`) & SSH Agent Forwarding (`ssh -A`)

- Gateway `sshd` enables `X11Forwarding yes` and `AllowAgentForwarding yes` on `login.<cluster>`.
- `route` detects `DISPLAY` and `SSH_AUTH_SOCK` on the gateway session (or installs an ephemeral unix-socket bridge when crossing `sudo`) and forwards `-X`/`-Y` and `-A` into the pod's `sshd` (which includes `xauth` in the base image).

## 5. File Transfers (`scp`, `sftp`, `rsync`, `rrsync`)

Handled directly on the gateway inside `login-gateway-xfer.slice` with **zero Slurm jobs**. See [`file-transfers.md`](./file-transfers.md).

## 6. Open OnDemand Web Shell

Open OnDemand's Shell app connects from the OOD pun host to `login.<cluster>` via SSH. Because OOD initiates a standard interactive PTY SSH session, it lands in the exact same persistent `login-<user>` pod as desktop SSH clients (reusing any already-running pod).

## 7. MFA Automation (`ssh user@robot.cluster ...`)

1. `robot.<cluster>` sets `AuthorizedKeysFile /dev/null` and queries `sss_ssh_authorizedkeys.filter --rewrite-dispatch`.
2. Each valid CCDB automation key (`restrict,from="...",command="<orig>"`) is emitted to `sshd` as `restrict,from="...",command="/usr/local/libexec/login-gateway/dispatch --robot --orig-cmd '<b64>' -- <orig>"`.
3. If the client runs a validated `scp`/`sftp`/`rsync` transfer (directly or through CVMFS `transfer_commands.sh`), `dispatch` executes it immediately on the gateway in `login-gateway-xfer.slice`.
4. Otherwise, `dispatch` invokes `sudo -n route --mode robot`, spawning a 2-CPU / 1-GB `robot-<user>` pod (no MOTD, no AI guardrails) and running the key's exact `command=` with `SSH_ORIGINAL_COMMAND` exported.
