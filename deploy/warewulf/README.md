# Warewulf 4 Overlay Templates

`render-overlays.sh` builds secret-free Warewulf 4 overlay trees directly from this repository:

| Overlay | Purpose | Assign To |
|---|---|---|
| `login-gateway` | Interactive SSH gateway (`dispatch`, `route`, `spawn`, `stop`, `classify-transfer`, `10-login-gateway.conf`, sudoers, systemd units) | `login.<cluster>` nodes |
| `robot-gateway` | Dedicated MFA automation gateway (`AuthorizedKeysFile /dev/null`, CCDB/LDAP keys filtered via `sss_ssh_authorizedkeys.filter --rewrite-dispatch`, `PermitTTY no`) | `robot.<cluster>` nodes |
| `cluster-status` | Generic pod-aware `cluster-status` banner + `cluster-status-bake.timer` | `login.<cluster>` nodes |
| `agent-guardrails` | System-wide AI coding agent policies (`claude-code`, `agents`, `codex`, `opencode`, `gemini-cli`, `pi`, `cursor`) + Alliance skills | `login.<cluster>` nodes |
| `login-pod-host` | Unprivileged userns sysctls, `/cache`, `/var/tmp`, and Enroot config | Nodes in the Slurm `login` partition |

## Layering with a Site Overlay

Keep all site-specific configuration, branding, and secrets in a separate site overlay placed **after** the generic overlays in the Warewulf profile so later overlays win:

```text
slurm,fixes,login-gateway,cluster-status,agent-guardrails,duo,<site-overlay>
```

Your `<site-overlay>` holds only site-specific files (for example `/etc/login-gateway/login-gateway.conf`, `/etc/cluster-status/motd.conf`, `/etc/cluster-status/logo.txt`, `/etc/cluster-status/links.txt`, `/etc/agents/site.md`, and optional `/etc/login-gateway/hooks/*`).

See [`docs/deploy-warewulf.md`](../../docs/deploy-warewulf.md) for the complete canary rollout workflow.
