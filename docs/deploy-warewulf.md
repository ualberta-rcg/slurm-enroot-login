# Deploying with Warewulf 4

`slurm-login-pods` separates **generic, reproducible overlays** (rendered from git with zero secrets) from your **private site overlay** (which stays inside Warewulf storage and holds site branding, hooks, and secrets).

## 1. Render Generic Overlays

On your management host:

```bash
deploy/warewulf/render-overlays.sh --output-dir /tmp/ww-login-pods --dry-run
deploy/warewulf/render-overlays.sh --output-dir /tmp/ww-login-pods
```

This creates:
- `/tmp/ww-login-pods/login-gateway/rootfs`
- `/tmp/ww-login-pods/robot-gateway/rootfs`
- `/tmp/ww-login-pods/cluster-status/rootfs`
- `/tmp/ww-login-pods/agent-guardrails/rootfs`
- `/tmp/ww-login-pods/login-pod-host/rootfs`

## 2. Import into Warewulf & Create Your Site Overlay

```bash
for ov in login-gateway cluster-status agent-guardrails; do
    wwctl overlay create "$ov" 2>/dev/null || true
    # Copy rendered tree into the Warewulf overlay rootfs
done
```

Create a site overlay (e.g. `<cluster>-site`) containing **only** site-specific files:
- `/etc/login-gateway/login-gateway.conf` (pointing `IMAGE_PATH` at `/cache/slurm-login-pods-<version>.sqsh`)
- `/etc/cluster-status/{motd.conf,logo.txt,links.txt,announce.txt}`
- `/etc/agents/site.md` (cluster partitions, GPUs, default walltimes)
- Optional `/etc/login-gateway/hooks/{identity,provision,motd}` (`0755` `root:root`)

## 3. Canary Profile Ordering (`login2` First)

In Warewulf 4, **later overlays override earlier overlays**. Place `<cluster>-site` after `login-gateway,cluster-status,agent-guardrails`:

```bash
wwctl profile add login-overlays-v2 \
    --system-overlays "slurm,fixes,login-gateway,cluster-status,agent-guardrails,duo,<cluster>-site"
```

1. Assign `login-overlays-v2` to **one canary login node** (e.g. `login2`) while keeping `login1` on the existing production profile.
2. Import the GitHub Actions-built container image into `/cache` with an explicit versioned filename so `login1`'s running pods are untouched:
   ```bash
   enroot import -o /cache/slurm-login-pods-<version>.sqsh docker://<org>/slurm-login-pods:<version>
   ```
3. Run `wwctl overlay build login2` and reboot `login2`.
4. Verify interactive SSH, VS Code Remote-SSH, `scp`/`rsync` (confirming `squeue` shows **zero** new jobs for transfers), robot keys, `cluster-status`, and `login-pod status` on `login2`.
5. Roll `login1` onto `login-overlays-v2`. Rolling back at any point is a single `wwctl node set` profile switch + reboot.
