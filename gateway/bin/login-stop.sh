#!/bin/bash
# /usr/local/bin/login-stop.sh
# Stops a user's login-<user>, robot-<user>, and/or admin-<user> container job
# and cleans up cached routing metadata and transient systemd units.
# admin-<user> jobs are owned by root (UID 0 allocation), not by the admin.
set -euo pipefail

CONF_FILE="/etc/loginbox/loginbox.conf"
[[ -r "$CONF_FILE" ]] && source "$CONF_FILE"

PARTITION="${LOGIN_PARTITION:-login}"
TARGET_USER=""
MODE="all"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --user|-u)
            TARGET_USER="${2:-}"
            shift 2
            ;;
        --mode|-m)
            MODE="${2:-all}"
            shift 2
            ;;
        *)
            if [[ -z "$TARGET_USER" ]]; then
                TARGET_USER="$1"
            fi
            shift
            ;;
    esac
done

if [[ -z "$TARGET_USER" || ! "$TARGET_USER" =~ ^[a-zA-Z0-9._-]+$ ]]; then
    echo "Usage: login-stop.sh --user <username> [--mode login|robot|admin|all]" >&2
    exit 1
fi

JOB_NAMES=()
UNITS=()
ROUTES=()

if [[ "$MODE" == "login" || "$MODE" == "all" ]]; then
    JOB_NAMES+=("login-${TARGET_USER}" "loginbox-${TARGET_USER}")
    UNITS+=("loginbox-salloc-${TARGET_USER}.service")
    ROUTES+=("/run/loginbox/routes/${TARGET_USER}")
fi

if [[ "$MODE" == "robot" || "$MODE" == "all" ]]; then
    JOB_NAMES+=("robot-${TARGET_USER}")
    UNITS+=("loginbox-robot-${TARGET_USER}.service")
    ROUTES+=("/run/loginbox/routes/robot-${TARGET_USER}")
fi

if [[ "$MODE" == "admin" || "$MODE" == "all" ]]; then
    JOB_NAMES+=("admin-${TARGET_USER}")
    UNITS+=("loginbox-admin-${TARGET_USER}.service")
    ROUTES+=("/run/loginbox/routes/admin-${TARGET_USER}")
fi

for r in "${ROUTES[@]}"; do
    rm -f "$r" 2>/dev/null || true
done

if [[ "$(id -u)" -eq 0 ]]; then
    for u in "${UNITS[@]}"; do
        systemctl stop "$u" 2>/dev/null || true
        systemctl reset-failed "$u" 2>/dev/null || true
    done
fi

for jname in "${JOB_NAMES[@]}"; do
    owner="$TARGET_USER"
    part="$PARTITION"
    if [[ "$jname" == admin-* ]]; then
        owner="root"
        part="${ADMIN_PARTITION:-$PARTITION}"
    fi
    JIDS=$(squeue -h -u "$owner" -p "$part" -n "$jname" -o "%i" 2>/dev/null || true)
    for jid in $JIDS; do
        scancel "$jid" 2>/dev/null || su -s /bin/bash "$TARGET_USER" -c "scancel $jid" 2>/dev/null || true
    done
done

for _ in $(seq 1 50); do
    still=""
    for jname in "${JOB_NAMES[@]}"; do
        owner="$TARGET_USER"
        part="$PARTITION"
        if [[ "$jname" == admin-* ]]; then
            owner="root"
            part="${ADMIN_PARTITION:-$PARTITION}"
        fi
        if [[ -n $(squeue -h -u "$owner" -p "$part" -n "$jname" -o "%i" 2>/dev/null) ]]; then
            still=1
            break
        fi
    done
    [[ -z "$still" ]] && break
    sleep 0.1
done
