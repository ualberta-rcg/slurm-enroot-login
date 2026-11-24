#!/usr/bin/env bash
# =============================================================================
# deploy/standalone/install.sh — Install slurm-login-pods on a standalone host
# =============================================================================
# Installs the login or robot SSH gateway scripts, sshd drop-in, sudoers,
# systemd units, and optional cluster-status and agent-guardrails onto a
# standalone Ubuntu/Debian/RHEL gateway node (not managed by Warewulf).
#
# Usage:
#   sudo deploy/standalone/install.sh --role {login|robot} \
#       [--with-status] [--with-guardrails] [--with-admin-pod] \
#       [--root /] [--dry-run]
# =============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ROLE=""
WITH_STATUS=0
WITH_GUARDRAILS=0
WITH_ADMIN_POD=0
DEST_ROOT="/"
DRY_RUN=0

usage() {
    cat <<'EOF'
Usage: install.sh --role {login|robot} [options]

Options:
  --role {login|robot}   Gateway role to configure (required)
  --with-status          Install cluster-status banner + systemd cache baker timer
  --with-guardrails      Install system-wide AI coding agent guardrails & Alliance skills
  --with-admin-pod       Enable ADMIN_POD_ENABLED=1 in initial login-gateway.conf
  --root DIR             Install under alternate root directory (default: /)
  --dry-run              Render into a temporary staging tree and print summary only
  -h, --help             Show this help message
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --role)            ROLE="${2:-}"; shift 2 ;;
        --with-status)     WITH_STATUS=1; shift ;;
        --with-guardrails) WITH_GUARDRAILS=1; shift ;;
        --with-admin-pod)  WITH_ADMIN_POD=1; shift ;;
        --root)            DEST_ROOT="${2:-/}"; shift 2 ;;
        --dry-run)         DRY_RUN=1; shift ;;
        -h|--help)         usage; exit 0 ;;
        *) echo "install.sh: unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
done

if [[ "$ROLE" != "login" && "$ROLE" != "robot" ]]; then
    echo "install.sh: --role must be 'login' or 'robot'" >&2
    usage >&2
    exit 2
fi

if [[ "$DRY_RUN" -eq 0 && "$DEST_ROOT" == "/" && "$(id -u)" -ne 0 ]]; then
    echo "install.sh: must run as root when installing to / (or pass --dry-run / --root)" >&2
    exit 1
fi

STAGE_DIR=$(mktemp -d)
trap 'rm -rf "$STAGE_DIR"' EXIT

OVERLAY_LIST="${ROLE}-gateway"
[[ "$WITH_STATUS" -eq 1 && "$ROLE" != "robot" ]] && OVERLAY_LIST+=",cluster-status"
[[ "$WITH_GUARDRAILS" -eq 1 && "$ROLE" != "robot" ]] && OVERLAY_LIST+=",agent-guardrails"

"$REPO_ROOT/deploy/warewulf/render-overlays.sh" --output-dir "$STAGE_DIR" --overlays "$OVERLAY_LIST" >/dev/null

MERGED="$STAGE_DIR/_merged"
mkdir -p "$MERGED"
IFS=',' read -r -a OVS <<< "$OVERLAY_LIST"
for ov in "${OVS[@]}"; do
    cp -a "$STAGE_DIR/$ov/rootfs/." "$MERGED/"
done

# Seed /etc/login-gateway/login-gateway.conf only if absent on target
TARGET_CONF="${DEST_ROOT%/}/etc/login-gateway/login-gateway.conf"
if [[ ! -f "$TARGET_CONF" ]]; then
    cp "$REPO_ROOT/login-gateway/etc/login-gateway/login-gateway.conf.example" "$MERGED/etc/login-gateway/login-gateway.conf"
    if [[ "$WITH_ADMIN_POD" -eq 1 ]]; then
        sed -i 's/^ADMIN_POD_ENABLED="0"/ADMIN_POD_ENABLED="1"/' "$MERGED/etc/login-gateway/login-gateway.conf"
    fi
fi

# Preserve existing /etc/cluster-status/motd.conf and announce.txt if already customized
if [[ -f "${DEST_ROOT%/}/etc/cluster-status/motd.conf" ]]; then
    rm -f "$MERGED/etc/cluster-status/motd.conf"
fi
if [[ -f "${DEST_ROOT%/}/etc/cluster-status/announce.txt" ]]; then
    rm -f "$MERGED/etc/cluster-status/announce.txt"
fi

# Validate sudoers syntax if visudo is installed
if command -v visudo >/dev/null 2>&1; then
    for sf in "$MERGED"/etc/sudoers.d/*; do
        [[ -f "$sf" ]] && visudo -cf "$sf" >/dev/null
    done
fi

FILE_COUNT=$(find "$MERGED" -mindepth 1 | wc -l)
if [[ "$DRY_RUN" -eq 1 ]]; then
    printf '[dry-run] standalone install (--role %s, overlays=%s): %d paths staged cleanly\n' "$ROLE" "$OVERLAY_LIST" "$FILE_COUNT"
    exit 0
fi

mkdir -p "$DEST_ROOT"
cp -a "$MERGED/." "$DEST_ROOT/"

if [[ "$DEST_ROOT" == "/" ]] && command -v systemd-tmpfiles >/dev/null 2>&1; then
    systemd-tmpfiles --create /etc/tmpfiles.d/login-gateway.conf 2>/dev/null || true
    systemctl daemon-reload 2>/dev/null || true
    systemctl enable --now login-gateway-keygen.service 2>/dev/null || true
    if [[ "$WITH_STATUS" -eq 1 && "$ROLE" != "robot" ]]; then
        systemctl enable --now cluster-status-bake.timer 2>/dev/null || true
        /usr/local/sbin/cluster-status-bake 2>/dev/null || true
    fi
fi

printf 'Installed slurm-login-pods (%s role, %d paths) into %s\n' "$ROLE" "$FILE_COUNT" "$DEST_ROOT"
printf 'Review %s/etc/login-gateway/login-gateway.conf and run `sshd -t && systemctl reload ssh` when ready.\n' "${DEST_ROOT%/}"
