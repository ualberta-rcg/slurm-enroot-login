#!/usr/bin/env bash
# =============================================================================
# render-overlays.sh — Render secret-free Warewulf 4 overlay trees from repo
# =============================================================================
# Produces generic, reproducible overlay rootfs directories ready for:
#   wwctl overlay import / rsync into /var/lib/warewulf/overlays/<name>/rootfs/
#
# Security guarantee:
#   Reads ONLY tracked repository templates and scripts. Never reads or copies
#   host keys, Duo secrets, LDAP bind credentials, or existing site overlays.
#
# Usage:
#   deploy/warewulf/render-overlays.sh --output-dir /tmp/ww-overlays [--overlays list] [--dry-run]
# =============================================================================
set -euo pipefail
umask 0022

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUTPUT_DIR=""
OVERLAYS="login-gateway,robot-gateway,cluster-status,agent-guardrails,login-pod-host"
DRY_RUN=0

usage() {
    cat <<'EOF'
Usage: render-overlays.sh --output-dir DIR [--overlays LIST] [--dry-run]

Overlays (comma-separated, default: all):
  login-gateway     Interactive Alliance SSH login gateway (ForceCommand dispatch -> pods + xfer fast-path)
  robot-gateway     Dedicated robot.<cluster> MFA automation gateway (CCDB keys only, strict from=/command=)
  cluster-status    Generic pod-aware login status banner + gateway cache baker timer
  agent-guardrails  System-wide AI coding agent guardrails & Alliance HPC skills
  login-pod-host    Minimal Pyxis/Enroot runtime directories & sysctl config for login-partition nodes
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --output-dir) OUTPUT_DIR="${2:-}"; shift 2 ;;
        --overlays)   OVERLAYS="${2:-}"; shift 2 ;;
        --dry-run)    DRY_RUN=1; shift ;;
        -h|--help)    usage; exit 0 ;;
        *) echo "render-overlays.sh: unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
done

if [[ -z "$OUTPUT_DIR" ]]; then
    echo "render-overlays.sh: --output-dir is required" >&2
    usage >&2
    exit 2
fi

render_gateway_common() {
    local root="$1"
    local role="$2" # login | robot

    mkdir -p \
        "$root/usr/local/libexec/login-gateway" \
        "$root/usr/local/bin" \
        "$root/usr/local/sbin" \
        "$root/usr/libexec/openssh" \
        "$root/etc/login-gateway/hooks" \
        "$root/etc/ssh/sshd_config.d" \
        "$root/etc/sudoers.d" \
        "$root/etc/systemd/system/multi-user.target.wants" \
        "$root/etc/tmpfiles.d"

    # Core gateway helpers
    install -m 0755 "$REPO_ROOT/login-gateway/libexec/dispatch" "$root/usr/local/libexec/login-gateway/dispatch"
    install -m 0755 "$REPO_ROOT/login-gateway/libexec/route" "$root/usr/local/libexec/login-gateway/route"
    install -m 0755 "$REPO_ROOT/login-gateway/libexec/spawn" "$root/usr/local/libexec/login-gateway/spawn"
    install -m 0755 "$REPO_ROOT/login-gateway/libexec/stop" "$root/usr/local/libexec/login-gateway/stop"
    install -m 0755 "$REPO_ROOT/login-gateway/libexec/classify-transfer" "$root/usr/local/libexec/login-gateway/classify-transfer"
    install -m 0755 "$REPO_ROOT/login-gateway/libexec/enter-login-container.sh" "$root/usr/local/libexec/login-gateway/enter-login-container.sh"

    install -m 0755 "$REPO_ROOT/login-gateway/bin/enter-login-job" "$root/usr/local/bin/enter-login-job"

    # Backward-compatibility symlinks for one release cycle
    ln -sfn ../libexec/login-gateway/route "$root/usr/local/bin/switch-user.sh"
    ln -sfn ../libexec/login-gateway/spawn "$root/usr/local/bin/login-spawn.sh"
    ln -sfn ../libexec/login-gateway/stop "$root/usr/local/bin/login-stop.sh"
    ln -sfn ../libexec/login-gateway/enter-login-container.sh "$root/usr/local/bin/enter-login-container.sh"

    # Authorized-keys helpers & strict Alliance robot key filter
    install -m 0755 "$REPO_ROOT/login-gateway/sbin/login-gateway-authorized-keys" "$root/usr/local/sbin/login-gateway-authorized-keys"
    install -m 0755 "$REPO_ROOT/login-gateway/sbin/sss_ssh_authorizedkeys.filter" "$root/usr/local/sbin/sss_ssh_authorizedkeys.filter"
    install -m 0755 "$REPO_ROOT/login-gateway/sbin/sss_ssh_authorizedkeys.filter.py" "$root/usr/local/sbin/sss_ssh_authorizedkeys.filter.py"
    ln -sfn login-gateway-authorized-keys "$root/usr/local/sbin/loginbox-authorized-keys"

    # RHEL/Alliance CVMFS sftp-server path compatibility symlink
    ln -sfn /usr/lib/openssh/sftp-server "$root/usr/libexec/openssh/sftp-server"

    # Config template & hook documentation (site overlay provides /etc/login-gateway/login-gateway.conf)
    install -m 0644 "$REPO_ROOT/login-gateway/etc/login-gateway/login-gateway.conf.example" "$root/etc/login-gateway/login-gateway.conf.example"
    install -m 0644 "$REPO_ROOT/login-gateway/hooks/README.md" "$root/etc/login-gateway/hooks/README.md"

    # sshd drop-ins
    install -m 0644 "$REPO_ROOT/login-gateway/etc/ssh/sshd_config.d/00-a_overrides.conf" "$root/etc/ssh/sshd_config.d/00-a_overrides.conf"
    if [[ "$role" == "robot" ]]; then
        install -m 0644 "$REPO_ROOT/login-gateway/etc/ssh/sshd_config.d/robot.conf.example" "$root/etc/ssh/sshd_config.d/10-robot-gateway.conf"
    else
        install -m 0644 "$REPO_ROOT/login-gateway/etc/ssh/sshd_config.d/login.conf.example" "$root/etc/ssh/sshd_config.d/10-login-gateway.conf"
    fi

    # Sudoers (0440 strictly required by sudo)
    chmod 0750 "$root/etc/sudoers.d"
    install -m 0440 "$REPO_ROOT/login-gateway/etc/sudoers.d/login-gateway" "$root/etc/sudoers.d/login-gateway"
    install -m 0440 "$REPO_ROOT/login-gateway/etc/sudoers.d/gateway-admins" "$root/etc/sudoers.d/gateway-admins"

    # Systemd units & tmpfiles
    install -m 0644 "$REPO_ROOT/login-gateway/etc/systemd/system/login-gateway-keygen.service" "$root/etc/systemd/system/login-gateway-keygen.service"
    install -m 0644 "$REPO_ROOT/login-gateway/etc/systemd/system/login-gateway-xfer.slice" "$root/etc/systemd/system/login-gateway-xfer.slice"
    ln -sfn ../login-gateway-keygen.service "$root/etc/systemd/system/multi-user.target.wants/login-gateway-keygen.service"
    install -m 0644 "$REPO_ROOT/login-gateway/etc/tmpfiles.d/login-gateway.conf" "$root/etc/tmpfiles.d/login-gateway.conf"
}

render_cluster_status() {
    local root="$1"
    mkdir -p \
        "$root/usr/local/bin" \
        "$root/usr/local/sbin" \
        "$root/etc/cluster-status" \
        "$root/etc/profile.d" \
        "$root/etc/systemd/system/timers.target.wants"

    install -m 0755 "$REPO_ROOT/status/bin/cluster-status" "$root/usr/local/bin/cluster-status"
    install -m 0755 "$REPO_ROOT/status/sbin/cluster-status-bake" "$root/usr/local/sbin/cluster-status-bake"
    install -m 0644 "$REPO_ROOT/status/etc/cluster-status/motd.conf.example" "$root/etc/cluster-status/motd.conf"
    install -m 0644 "$REPO_ROOT/status/etc/cluster-status/announce.txt" "$root/etc/cluster-status/announce.txt"
    install -m 0644 "$REPO_ROOT/status/etc/profile.d/zz-cluster-status.sh" "$root/etc/profile.d/zz-cluster-status.sh"
    install -m 0644 "$REPO_ROOT/status/etc/systemd/system/cluster-status-bake.service" "$root/etc/systemd/system/cluster-status-bake.service"
    install -m 0644 "$REPO_ROOT/status/etc/systemd/system/cluster-status-bake.timer" "$root/etc/systemd/system/cluster-status-bake.timer"
    ln -sfn ../cluster-status-bake.timer "$root/etc/systemd/system/timers.target.wants/cluster-status-bake.timer"
}

render_agent_guardrails() {
    local root="$1"
    mkdir -p "$root/etc" "$root/usr/share/agent-guardrails"
    cp -a "$REPO_ROOT/agent-guardrails/etc/." "$root/etc/"
    cp -a "$REPO_ROOT/agent-guardrails/skills" "$root/usr/share/agent-guardrails/skills"

    rm -rf "$root/etc/claude-code/.claude/skills" "$root/etc/agents/skills" "$root/etc/codex/skills"
    mkdir -p "$root/etc/claude-code/.claude"
    cp -a "$REPO_ROOT/agent-guardrails/skills" "$root/etc/claude-code/.claude/skills"
    ln -sfn ../claude-code/.claude/skills "$root/etc/agents/skills"
    ln -sfn ../agents/skills "$root/etc/codex/skills"

    chmod -R a+rX "$root/etc/claude-code" "$root/etc/agents" "$root/etc/codex" \
        "$root/etc/opencode" "$root/etc/gemini-cli" "$root/etc/pi" "$root/etc/cursor" \
        "$root/usr/share/agent-guardrails"
    chmod 0755 "$root/etc/claude-code/update-motd.sh"
    chmod 0644 "$root/etc/profile.d/ai-agent-skills.sh"
    [[ -f "$root/etc/cron.d/claude-motd" ]] && chmod 0644 "$root/etc/cron.d/claude-motd"
}

render_login_pod_host() {
    local root="$1"
    mkdir -p \
        "$root/etc/sysctl.d" \
        "$root/etc/tmpfiles.d" \
        "$root/etc/enroot/enroot.conf.d" \
        "$root/etc/slurm/plugstack.d"

    cat > "$root/etc/sysctl.d/90-login-pods-userns.conf" <<'EOF'
# Required for unprivileged Enroot/Pyxis login-<user> & robot-<user> pods
user.max_user_namespaces = 65536
kernel.unprivileged_userns_clone = 1
EOF
    cat > "$root/etc/tmpfiles.d/login-pod-host.conf" <<'EOF'
d /cache 0755 root root -
d /var/tmp 1777 root root -
EOF
    cat > "$root/etc/enroot/enroot.conf.d/10-login-pods.conf" <<'EOF'
# Login-pod Enroot defaults (use FUSE squashfs mount for unprivileged user pods)
ENROOT_SQUASH_OPTIONS -noI -noD -noF -noX -no-duplicates
ENROOT_MOUNT_HOME no
ENROOT_RESTRICT_DEV yes
ENROOT_ROOTFS_WRITABLE yes
EOF
    install -m 0644 "$REPO_ROOT/slurm/pyxis.conf.example" "$root/etc/slurm/plugstack.d/pyxis.conf.example"
}

IFS=',' read -r -a REQ_OVERLAYS <<< "$OVERLAYS"

if [[ "$DRY_RUN" -eq 1 ]]; then
    WORK_DIR=$(mktemp -d)
    trap 'rm -rf "$WORK_DIR"' EXIT
    TARGET_BASE="$WORK_DIR"
else
    mkdir -p "$OUTPUT_DIR"
    TARGET_BASE="$OUTPUT_DIR"
fi

for ov in "${REQ_OVERLAYS[@]}"; do
    ov="${ov// /}"
    [[ -z "$ov" ]] && continue
    ov_root="${TARGET_BASE}/${ov}/rootfs"
    rm -rf "${TARGET_BASE:?}/${ov}"
    mkdir -p "$ov_root"
    case "$ov" in
        login-gateway)    render_gateway_common "$ov_root" "login" ;;
        robot-gateway)    render_gateway_common "$ov_root" "robot" ;;
        cluster-status)   render_cluster_status "$ov_root" ;;
        agent-guardrails) render_agent_guardrails "$ov_root" ;;
        login-pod-host)   render_login_pod_host "$ov_root" ;;
        *) echo "render-overlays.sh: unknown overlay '$ov'" >&2; exit 2 ;;
    esac
    file_count=$(find "$ov_root" -mindepth 1 | wc -l)
    if [[ "$DRY_RUN" -eq 1 ]]; then
        printf '[dry-run] would render overlay %-18s -> %s/%s/rootfs (%d paths)\n' "$ov" "$OUTPUT_DIR" "$ov" "$file_count"
    else
        printf 'rendered overlay %-18s -> %s/%s/rootfs (%d paths)\n' "$ov" "$OUTPUT_DIR" "$ov" "$file_count"
    fi
done
