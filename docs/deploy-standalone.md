# Deploying on Standalone Hosts

For gateway VMs or bare-metal login nodes managed with standard packages/Ansible rather than Warewulf:

## 1. Prerequisites

1. Slurm client commands (`srun`, `squeue`, `scontrol`, `scancel`, `sinfo`, `sacct`, `sshare`) configured and Munge running (`/run/munge/munge.socket.2`).
2. Slurm `login` partition + Pyxis + Enroot configured on the execution host(s) (see [`slurm-config.md`](./slurm-config.md) and [`deploy/ansible/05-enroot-pyxis-node.yaml`](../deploy/ansible/05-enroot-pyxis-node.yaml)).
3. SquashFS pod image imported to shared `/cache` (or local `/cache` on every `login` partition node):
   ```bash
   sudo mkdir -p /cache
   sudo enroot import -o /cache/slurm-login-pods.sqsh docker://<org>/slurm-login-pods:latest
   ```
4. SSSD/LDAP + `pam_duo.so` configured on `login.<cluster>` (example PAM stack at `login-gateway/etc/pam.d/sshd.example`).

## 2. Install the Interactive Login Gateway (`login.<cluster>`)

```bash
# Preview changes first
sudo deploy/standalone/install.sh --role login --with-status --with-guardrails --dry-run

# Install
sudo deploy/standalone/install.sh --role login --with-status --with-guardrails

# Customize /etc/login-gateway/login-gateway.conf and /etc/cluster-status/motd.conf
sudo editor /etc/login-gateway/login-gateway.conf
sudo editor /etc/cluster-status/motd.conf

# Validate sshd configuration and reload
sudo sshd -t && sudo systemctl reload ssh
```

## 3. Install the Dedicated Automation Gateway (`robot.<cluster>`)

```bash
sudo deploy/standalone/install.sh --role robot --dry-run
sudo deploy/standalone/install.sh --role robot

sudo editor /etc/login-gateway/login-gateway.conf
sudo sshd -t && sudo systemctl reload ssh
```

## 4. Optional Host Playbooks

- Clean up default Ubuntu MOTD scripts so `cluster-status` renders cleanly:
  ```bash
  sudo ansible-playbook deploy/ansible/89-motd-cleanup.yaml
  ```
- Install Codex, Antigravity, OpenCode, and Claude Code CLIs on the gateway fallback host:
  ```bash
  sudo ansible-playbook deploy/ansible/93-ai-agents.yaml
  ```
