# /etc/profile.d/zz-cluster-status.sh — login status banner hook.
# Exposes /etc/cluster-status/bin on PATH for ALL login shells (including
# non-interactive agent tool calls), while keeping banner output strictly
# interactive-only.

if [ -d /etc/cluster-status/bin ]; then
    case ":${PATH:-}:" in
        *:/etc/cluster-status/bin:*) ;;
        *) PATH="${PATH:+$PATH:}/etc/cluster-status/bin"; export PATH ;;
    esac
fi

case $- in
    *i*) ;;
    *) return 0 2>/dev/null || exit 0 ;;
esac

# Optional site command alias (e.g. STATUS_CMD_NAME="mycluster-status" in motd.conf)
# so generic login-pod images support the site's status command name without
# rebuilding the container image.
if [ -r /etc/cluster-status/motd.conf ]; then
    _status_cmd_name=$(awk -F= '/^[[:space:]]*STATUS_CMD_NAME=/{gsub(/["'\''[:space:]]/, "", $2); print $2; exit}' /etc/cluster-status/motd.conf 2>/dev/null)
    case "${_status_cmd_name:-}" in
        ''|cluster-status|*[!A-Za-z0-9_-]*) ;;
        *)
            if ! command -v "$_status_cmd_name" >/dev/null 2>&1 && command -v cluster-status >/dev/null 2>&1; then
                alias "$_status_cmd_name=cluster-status" 2>/dev/null || true
            fi
            ;;
    esac
    unset _status_cmd_name
fi

[ -t 1 ] || return 0 2>/dev/null || exit 0
case "${TERM:-dumb}" in
    ''|dumb) return 0 2>/dev/null || exit 0 ;;
esac
[ "${LOGIN_SESSION_MODE:-login}" = "robot" ] && { return 0 2>/dev/null || exit 0; }
[ "${LOGIN_STATUS_ENABLED:-1}" = "0" ] && { return 0 2>/dev/null || exit 0; }
[ "$(id -u)" -eq 0 ] && { return 0 2>/dev/null || exit 0; }
[ -n "${CLUSTER_STATUS_OFF:-${VULCAN_MOTD_OFF:-}}" ] && { return 0 2>/dev/null || exit 0; }
[ -e "${HOME:-/nonexistent}/.hushlogin" ] && { return 0 2>/dev/null || exit 0; }

[ -n "${CLUSTER_STATUS_SHOWN:-}" ] && { return 0 2>/dev/null || exit 0; }
CLUSTER_STATUS_SHOWN=1; export CLUSTER_STATUS_SHOWN

command -v cluster-status >/dev/null 2>&1 && timeout 6 cluster-status
true
