#!/bin/bash
# /usr/local/bin/login-helper.sh
# Login shell for the 'cilogon' NSS shim user on login gateway nodes.
# Preserves X11 cookie/DISPLAY, SSH_AUTH_SOCK, SSH_ORIGINAL_COMMAND, and
# OpenSSH ExposeAuthInfo method across sudo into switch-user.sh, resolving
# TARGET_USER from PAM_OAUTH2_PROVISIONED_USER (CILogon device flow) or
# /run/loginbox/pam-session/pid.<priv_pid> (pubkey / internal / robot flows).

TARGET_USER="${PAM_OAUTH2_PROVISIONED_USER:-}"
if [[ -z "$TARGET_USER" && -r "/proc/${PPID}/status" ]]; then
    PRIV_PID=$(awk '/^PPid:/ {print $2}' "/proc/${PPID}/status" 2>/dev/null || true)
    if [[ -n "$PRIV_PID" && -r "/run/loginbox/pam-session/pid.${PRIV_PID}" ]]; then
        TARGET_USER=$(cat "/run/loginbox/pam-session/pid.${PRIV_PID}" 2>/dev/null || true)
    fi
fi

X11_COOKIE=""
if [[ -n "${DISPLAY:-}" ]]; then
    X11_COOKIE=$(/usr/bin/xauth list "$DISPLAY" 2>/dev/null | head -n 1 || true)
fi

AUTH_TYPE=""
if [[ -n "${SSH_USER_AUTH:-}" && -r "${SSH_USER_AUTH}" ]]; then
    AUTH_TYPE=$(awk 'NR==1 {print $1}' "${SSH_USER_AUTH}" 2>/dev/null || true)
fi

exec sudo \
    LOGINBOX_ORIG_DISPLAY="${DISPLAY:-}" \
    LOGINBOX_ORIG_X11_COOKIE="${X11_COOKIE:-}" \
    LOGINBOX_ORIG_AUTH_SOCK="${SSH_AUTH_SOCK:-}" \
    LOGINBOX_ORIG_TERM="${TERM:-xterm-256color}" \
    LOGINBOX_ORIG_SSH_CONNECTION="${SSH_CONNECTION:-}" \
    LOGINBOX_ORIG_SSH_ORIGINAL_COMMAND="${SSH_ORIGINAL_COMMAND:-}" \
    LOGINBOX_ORIG_AUTH_TYPE="${AUTH_TYPE:-}" \
    LOGINBOX_FORCE_CONTAINER="${LOGINBOX_FORCE_CONTAINER:-}" \
    LOGINBOX_FORCE_ROBOT="${LOGINBOX_FORCE_ROBOT:-}" \
    LOGINBOX_FORCE_ADMIN="${LOGINBOX_FORCE_ADMIN:-}" \
    LOGINBOX_FORCE_HOST="${LOGINBOX_FORCE_HOST:-}" \
    /usr/local/bin/switch-user.sh "${TARGET_USER}" "$@"
