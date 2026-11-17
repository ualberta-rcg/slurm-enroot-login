#!/bin/bash
# /usr/local/bin/switch-user.sh
# Invoked via sudo from /usr/local/bin/login-helper.sh for all Port-22 SSH sessions:
#   switch-user.sh <TARGET_USER> [-c "<command>"]
#
# Routing Precedence:
#   1. Port-22 Robot Detection: identifies restricted robot key sessions
#      (`__LOGINBOX_ROBOT__` marker and/or external publickey auth), verifies
#      membership in ROBOT_GROUP, and restores original forced command.
#   2. Direct Gateway File Transfers (`scp`, `sftp-server`, `rsync --server`,
#      `rrsync`): validated against shell-metacharacter smuggling and executed
#      directly on the gateway host inside a per-user cgroup scope (0 Slurm jobs).
#   3. Gateway Admin Bypass (`GATEWAY_BYPASS_GROUPS`, e.g. `gateway-admins` /
#      `ccstaff`): drops admins directly onto the gateway host with PTY ownership,
#      X11, and SSH agent forwarded cleanly (unless `LOGINBOX_FORCE_CONTAINER=1`
#      or `enter-login-job` / `container` is requested).
#   4. Slurm Container Routing:
#      - Normal sessions -> `login-<user>` (`LOGIN_CPUS` / `LOGIN_MEM`)
#      - Robot sessions  -> `robot-<user>` (`ROBOT_CPUS` / `ROBOT_MEM`, less RAM)
#      Attaches over internal cluster network with pinned container host key.
set -uo pipefail

CONF_FILE="/etc/loginbox/loginbox.conf"
[[ -r "$CONF_FILE" ]] && source "$CONF_FILE"

LOGIN_PARTITION="${LOGIN_PARTITION:-login}"
GATEWAY_BYPASS_GROUPS="${GATEWAY_BYPASS_GROUPS:-gateway-admins ccstaff}"
ROBOT_GROUP="${ROBOT_GROUP:-mfa-automation-users}"
INTERNAL_CIDRS="${INTERNAL_CIDRS:-10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,127.0.0.0/8}"
XFER_MEM_MAX="${XFER_MEM_MAX:-512M}"
XFER_CPU_QUOTA="${XFER_CPU_QUOTA:-100%}"
XFER_TASKS_MAX="${XFER_TASKS_MAX:-32}"

NORMALIZED_XFER_CMD=""

classify_transfer_cmd() {
    local cmd="${1:-}"
    local orig_cmd="${2:-}"
    NORMALIZED_XFER_CMD=""

    [[ -z "$cmd" ]] && return 1

    # Reject newlines/CR and any shell command-chaining, redirection, or subshell expansion
    if [[ "$cmd" == *$'\n'* || "$cmd" == *$'\r'* ]]; then
        return 1
    fi
    if [[ "$cmd" == *";"* || "$cmd" == *"|"* || "$cmd" == *"&"* || "$cmd" == *'`'* || "$cmd" == *'$('* || "$cmd" == *'${'* || "$cmd" == *">"* || "$cmd" == *"<"* ]]; then
        return 1
    fi

    # Trim leading whitespace
    cmd="${cmd#"${cmd%%[![:space:]]*}"}"
    [[ -z "$cmd" ]] && return 1

    local first_tok rest=""
    if [[ "$cmd" == *[[:space:]]* ]]; then
        first_tok="${cmd%%[[:space:]]*}"
        rest="${cmd#*[[:space:]]}"
        rest="${rest#"${rest%%[![:space:]]*}"}"
    else
        first_tok="$cmd"
    fi

    case "$first_tok" in
        sftp-server|/usr/lib/openssh/sftp-server|/usr/libexec/openssh/sftp-server|internal-sftp)
            if [[ -n "$rest" ]]; then
                NORMALIZED_XFER_CMD="/usr/lib/openssh/sftp-server ${rest}"
            else
                NORMALIZED_XFER_CMD="/usr/lib/openssh/sftp-server"
            fi
            return 0
            ;;
        scp|/usr/bin/scp)
            [[ -z "$rest" ]] && return 1
            local tok has_tf=0
            for tok in $rest; do
                [[ "$tok" == "--" ]] && break
                [[ "$tok" != -* ]] && break
                if [[ "$tok" =~ ^-[rpdqvfCtO]*[tf][rpdqvfCtO]*$ ]]; then
                    has_tf=1
                    break
                fi
            done
            [[ "$has_tf" -ne 1 ]] && return 1
            NORMALIZED_XFER_CMD="/usr/bin/scp ${rest}"
            return 0
            ;;
        rsync|/usr/bin/rsync)
            [[ -z "$rest" ]] && return 1
            local first_arg="${rest%%[[:space:]]*}"
            [[ "$first_arg" != "--server" ]] && return 1
            NORMALIZED_XFER_CMD="/usr/bin/rsync ${rest}"
            return 0
            ;;
        rrsync|/usr/bin/rrsync|/usr/local/bin/rrsync)
            [[ -z "$orig_cmd" ]] && return 1
            if [[ "$orig_cmd" == *$'\n'* || "$orig_cmd" == *$'\r'* || "$orig_cmd" == *";"* || "$orig_cmd" == *"|"* || "$orig_cmd" == *"&"* || "$orig_cmd" == *'`'* || "$orig_cmd" == *'$('* || "$orig_cmd" == *'${'* || "$orig_cmd" == *">"* || "$orig_cmd" == *"<"* ]]; then
                return 1
            fi
            local orig_trimmed="${orig_cmd#"${orig_cmd%%[![:space:]]*}"}"
            if [[ "$orig_trimmed" != "rsync --server"* && "$orig_trimmed" != "/usr/bin/rsync --server"* ]]; then
                return 1
            fi
            local rrsync_bin="/usr/bin/rrsync"
            [[ -x /usr/local/bin/rrsync && ! -x /usr/bin/rrsync ]] && rrsync_bin="/usr/local/bin/rrsync"
            if [[ -n "$rest" ]]; then
                NORMALIZED_XFER_CMD="${rrsync_bin} ${rest}"
            else
                NORMALIZED_XFER_CMD="${rrsync_bin}"
            fi
            return 0
            ;;
    esac

    return 1
}

# Pure classifier mode for automated unit tests
if [[ "${1:-}" == "--classify-transfer" ]]; then
    if classify_transfer_cmd "${2:-}" "${3:-}"; then
        echo "$NORMALIZED_XFER_CMD"
        exit 0
    fi
    exit 1
fi

CLI_FORCE_CONTAINER="0"
CLI_FORCE_ROBOT="0"
while [[ "${1:-}" == --force-* ]]; do
    case "$1" in
        --force-container) CLI_FORCE_CONTAINER="1"; shift ;;
        --force-robot)     CLI_FORCE_ROBOT="1"; shift ;;
        *) break ;;
    esac
done

TARGET_USER="${1:-}"
if [[ -z "$TARGET_USER" || ! "$TARGET_USER" =~ ^[a-zA-Z0-9._-]+$ ]]; then
    echo "ERROR: valid target user not specified." >&2
    exit 1
fi
shift

PW_LINE=$(getent -s sss passwd "$TARGET_USER" 2>/dev/null || getent passwd "$TARGET_USER" 2>/dev/null || true)
if [[ -z "$PW_LINE" ]]; then
    echo "ERROR: unable to resolve user ${TARGET_USER}." >&2
    exit 1
fi
IFS=":" read -r _pw_name _pw_x USER_UID USER_GID _pw_gecos USER_HOME USER_SHELL <<< "$PW_LINE"
[[ -z "$USER_HOME" ]] && USER_HOME="/home/${TARGET_USER}"
[[ -z "$USER_SHELL" ]] && USER_SHELL="/bin/bash"

IS_TTY=0
if [[ -t 0 && ( -t 1 || -t 2 ) ]]; then
    IS_TTY=1
fi

is_internal_client() {
    local conn="${LOGINBOX_ORIG_SSH_CONNECTION:-}"
    [[ -z "$conn" ]] && return 1
    local client_ip="${conn%% *}"
    python3 - "$client_ip" "$INTERNAL_CIDRS" << 'PYEOF' >/dev/null 2>&1
import ipaddress, sys
ip = ipaddress.ip_address(sys.argv[1])
for raw in sys.argv[2].split(","):
    raw = raw.strip()
    if raw and ip in ipaddress.ip_network(raw, strict=False):
        sys.exit(0)
sys.exit(1)
PYEOF
}

user_in_group_list() {
    local target_groups="$1"
    local user_groups
    user_groups=" $(id -Gn "$TARGET_USER" 2>/dev/null || true) "
    local g
    for g in $target_groups; do
        if [[ "$user_groups" == *" ${g} "* ]]; then
            return 0
        fi
    done
    return 1
}

# ── 1. Detect Port-22 Robot Session ──────────────────────────────────────────
SESSION_MODE="login"
if [[ "${LOGINBOX_FORCE_ROBOT:-0}" == "1" || "$CLI_FORCE_ROBOT" == "1" ]]; then
    SESSION_MODE="robot"
fi

if [[ $# -ge 2 && "${1:-}" == "-c" && "${2:-}" == "__LOGINBOX_ROBOT__ "* ]]; then
    ROBOT_CMD="${2#__LOGINBOX_ROBOT__ }"
    SESSION_MODE="robot"
    set -- "-c" "$ROBOT_CMD"
elif [[ "${LOGINBOX_ORIG_AUTH_TYPE:-}" == "publickey" ]] && ! is_internal_client; then
    # Defense-in-depth: any external publickey login on Port 22 is treated as robot
    SESSION_MODE="robot"
fi

if [[ "$SESSION_MODE" == "robot" ]]; then
    if ! user_in_group_list "$ROBOT_GROUP"; then
        echo "ERROR: user ${TARGET_USER} is not authorized for robot SSH access (${ROBOT_GROUP})." >&2
        exit 1
    fi
    if [[ -n "${LOGINBOX_ORIG_SSH_ORIGINAL_COMMAND:-}" ]]; then
        export SSH_ORIGINAL_COMMAND="${LOGINBOX_ORIG_SSH_ORIGINAL_COMMAND}"
    fi
fi

# ── 2. Direct Gateway File Transfer Fast-Path (scp / sftp / rsync / rrsync) ──
if [[ $# -ge 2 && "${1:-}" == "-c" ]]; then
    if classify_transfer_cmd "$2" "${LOGINBOX_ORIG_SSH_ORIGINAL_COMMAND:-}"; then
        ls -d "${USER_HOME}/." >/dev/null 2>&1 || true
        cd "$USER_HOME" 2>/dev/null || cd /tmp

        XFER_ENV=(
            HOME="$USER_HOME"
            USER="$TARGET_USER"
            LOGNAME="$TARGET_USER"
            SHELL="$USER_SHELL"
            PATH="/usr/local/bin:/usr/bin:/bin"
            LANG="${LANG:-C.UTF-8}"
        )
        if [[ -n "${LOGINBOX_ORIG_SSH_ORIGINAL_COMMAND:-}" ]]; then
            XFER_ENV+=(SSH_ORIGINAL_COMMAND="${LOGINBOX_ORIG_SSH_ORIGINAL_COMMAND}")
        fi

        if [[ -S /run/systemd/private ]] && command -v systemd-run >/dev/null 2>&1; then
            exec systemd-run --quiet --scope \
                --slice=loginbox-xfer.slice \
                --property="MemoryMax=${XFER_MEM_MAX}" \
                --property="CPUQuota=${XFER_CPU_QUOTA}" \
                --property="TasksMax=${XFER_TASKS_MAX}" \
                env -i "${XFER_ENV[@]}" \
                setpriv --reuid="$USER_UID" --regid="$USER_GID" --init-groups \
                /bin/bash -c "$NORMALIZED_XFER_CMD"
        else
            exec env -i "${XFER_ENV[@]}" \
                setpriv --reuid="$USER_UID" --regid="$USER_GID" --init-groups \
                /bin/bash -c "$NORMALIZED_XFER_CMD"
        fi
    fi
fi

# Allow explicit opt-in container entry (`ssh -t host container`, `--force-container`, or `LOGINBOX_FORCE_CONTAINER=1`)
FORCE_CONTAINER="${LOGINBOX_FORCE_CONTAINER:-0}"
[[ "$CLI_FORCE_CONTAINER" == "1" ]] && FORCE_CONTAINER="1"
if [[ "${1:-}" == "container" ]]; then
    FORCE_CONTAINER="1"
    shift
elif [[ "${1:-}" == "-c" && "${2:-}" == "container" ]]; then
    FORCE_CONTAINER="1"
    set --
fi

# ── 3. Gateway Admin Host Bypass (`gateway-admins` / `ccstaff`) ──────────────
if [[ "$SESSION_MODE" == "login" && "$FORCE_CONTAINER" != "1" ]] && user_in_group_list "$GATEWAY_BYPASS_GROUPS"; then
    ls -d "${USER_HOME}/." >/dev/null 2>&1 || true

    USER_RT_DIR="/run/loginbox/user-runtime/${USER_UID}"
    mkdir -p /run/loginbox/user-runtime "$USER_RT_DIR" 2>/dev/null || true
    chmod 755 /run/loginbox /run/loginbox/user-runtime 2>/dev/null || true
    chown "${USER_UID}:${USER_GID}" "$USER_RT_DIR" 2>/dev/null || true
    chmod 700 "$USER_RT_DIR" 2>/dev/null || true

    HOST_ENV=(
        HOME="$USER_HOME"
        USER="$TARGET_USER"
        LOGNAME="$TARGET_USER"
        SHELL="$USER_SHELL"
        TERM="${LOGINBOX_ORIG_TERM:-${TERM:-xterm-256color}}"
        LANG="${LANG:-C.UTF-8}"
        PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
    )
    [[ -n "${LOGINBOX_ORIG_SSH_CONNECTION:-}" ]] && HOST_ENV+=(SSH_CONNECTION="${LOGINBOX_ORIG_SSH_CONNECTION}")

    if [[ -n "${LOGINBOX_ORIG_DISPLAY:-}" && -n "${LOGINBOX_ORIG_X11_COOKIE:-}" ]]; then
        HOST_XAUTH="${USER_RT_DIR}/Xauthority"
        touch "$HOST_XAUTH"
        chmod 600 "$HOST_XAUTH"
        read -r _x_disp _x_proto _x_hex <<< "$LOGINBOX_ORIG_X11_COOKIE"
        if [[ -n "${_x_hex:-}" ]]; then
            /usr/bin/xauth -f "$HOST_XAUTH" add "$LOGINBOX_ORIG_DISPLAY" "${_x_proto:-MIT-MAGIC-COOKIE-1}" "$_x_hex" >/dev/null 2>&1 || true
            chown "${USER_UID}:${USER_GID}" "$HOST_XAUTH" 2>/dev/null || true
            HOST_ENV+=(DISPLAY="$LOGINBOX_ORIG_DISPLAY" XAUTHORITY="$HOST_XAUTH")
        fi
    fi

    if [[ -n "${LOGINBOX_ORIG_AUTH_SOCK:-}" && -S "${LOGINBOX_ORIG_AUTH_SOCK}" ]]; then
        SOCK_DIR=$(dirname "$LOGINBOX_ORIG_AUTH_SOCK")
        if [[ "$SOCK_DIR" == /tmp/ssh-* ]]; then
            chown -R "${USER_UID}:${USER_GID}" "$SOCK_DIR" 2>/dev/null || true
            HOST_ENV+=(SSH_AUTH_SOCK="$LOGINBOX_ORIG_AUTH_SOCK")
        fi
    fi

    if [[ "$IS_TTY" -eq 1 ]]; then
        TTY_DEV=$(tty 2>/dev/null || true)
        if [[ "$TTY_DEV" == /dev/pts/* ]]; then
            chown "${USER_UID}:tty" "$TTY_DEV" 2>/dev/null || true
            chmod 620 "$TTY_DEV" 2>/dev/null || true
        fi
        if [[ $# -eq 0 && ! -f "${USER_HOME}/.hushlogin" && -f /etc/motd ]]; then
            cat /etc/motd
        fi
    fi

    cd "$USER_HOME" 2>/dev/null || cd /tmp
    if [[ $# -eq 0 ]]; then
        exec env -i "${HOST_ENV[@]}" \
            setpriv --reuid="$USER_UID" --regid="$USER_GID" --init-groups \
            "$USER_SHELL" -l
    elif [[ "${1:-}" == "-c" && $# -ge 2 ]]; then
        exec env -i "${HOST_ENV[@]}" \
            setpriv --reuid="$USER_UID" --regid="$USER_GID" --init-groups \
            "$USER_SHELL" -c "$2"
    else
        exec env -i "${HOST_ENV[@]}" \
            setpriv --reuid="$USER_UID" --regid="$USER_GID" --init-groups \
            "$@"
    fi
fi

# ── 4. Slurm Container Job Routing (`login-<user>` vs `robot-<user>`) ────────
ROUTE_DIR="/run/loginbox/routes"
if [[ "$SESSION_MODE" == "robot" ]]; then
    JOB_NAME="robot-${TARGET_USER}"
    ROUTE_FILE="${ROUTE_DIR}/robot-${TARGET_USER}"
else
    JOB_NAME="login-${TARGET_USER}"
    ROUTE_FILE="${ROUTE_DIR}/${TARGET_USER}"
fi

if [[ -f /etc/loginbox/proxy_id_ed25519 ]]; then
    PROXY_KEY="/etc/loginbox/proxy_id_ed25519"
else
    PROXY_KEY="/tmp/loginbox-cssh/proxy_id_ed25519"
fi

SSH_EXTRA_FLAGS=()
TEMP_XAUTH=""
TEMP_KNOWN_HOSTS=""
cleanup_temp() {
    [[ -n "$TEMP_XAUTH" && -f "$TEMP_XAUTH" ]] && rm -f "$TEMP_XAUTH"
    [[ -n "$TEMP_KNOWN_HOSTS" && -f "$TEMP_KNOWN_HOSTS" ]] && rm -f "$TEMP_KNOWN_HOSTS"
}
trap cleanup_temp EXIT

if [[ "$SESSION_MODE" != "robot" ]]; then
    if [[ -n "${LOGINBOX_ORIG_DISPLAY:-}" && -n "${LOGINBOX_ORIG_X11_COOKIE:-}" ]]; then
        mkdir -p /run/loginbox/xauth 2>/dev/null || true
        chmod 700 /run/loginbox/xauth 2>/dev/null || true
        TEMP_XAUTH="/run/loginbox/xauth/xauth.${TARGET_USER}.$$"
        touch "$TEMP_XAUTH"
        chmod 600 "$TEMP_XAUTH"
        read -r _x_disp _x_proto _x_hex <<< "$LOGINBOX_ORIG_X11_COOKIE"
        if [[ -n "${_x_hex:-}" ]]; then
            /usr/bin/xauth -f "$TEMP_XAUTH" add "$LOGINBOX_ORIG_DISPLAY" "${_x_proto:-MIT-MAGIC-COOKIE-1}" "$_x_hex" >/dev/null 2>&1 || true
            export DISPLAY="$LOGINBOX_ORIG_DISPLAY"
            export XAUTHORITY="$TEMP_XAUTH"
            SSH_EXTRA_FLAGS+=("-Y")
        fi
    fi

    if [[ -n "${LOGINBOX_ORIG_AUTH_SOCK:-}" && -S "${LOGINBOX_ORIG_AUTH_SOCK}" ]]; then
        export SSH_AUTH_SOCK="$LOGINBOX_ORIG_AUTH_SOCK"
        SSH_EXTRA_FLAGS+=("-A")
    fi
fi

export TERM="${LOGINBOX_ORIG_TERM:-${TERM:-xterm-256color}}"

tcp_probe() {
    local host="$1" port="$2"
    timeout 0.2 bash -c "</dev/tcp/${host}/${port}" >/dev/null 2>&1
}

resolve_or_spawn() {
    mkdir -p "$ROUTE_DIR" 2>/dev/null || true
    chmod 755 /run/loginbox "$ROUTE_DIR" 2>/dev/null || true

    local job_info
    job_info=$(squeue -h -u "$TARGET_USER" -p "$LOGIN_PARTITION" -n "$JOB_NAME" -t R -o "%i|%N|%k" 2>/dev/null | head -n 1 || true)
    if [[ -n "$job_info" ]]; then
        IFS="|" read -r s_jid _s_node s_comment <<< "$job_info"
        if [[ "$s_comment" == *:*:* ]]; then
            IFS=":" read -r c_node c_port c_fp <<< "$s_comment"
            if [[ -n "$c_node" && -n "$c_port" ]] && tcp_probe "$c_node" "$c_port"; then
                echo "${s_jid}|${c_node}|${c_port}|${c_fp}" > "$ROUTE_FILE" 2>/dev/null || true
                chmod 644 "$ROUTE_FILE" 2>/dev/null || true
                JID="$s_jid"
                CNODE="$c_node"
                CPORT="$c_port"
                CFP="$c_fp"
                return 0
            fi
        fi
    fi

    if [[ "$IS_TTY" -eq 1 && "$SESSION_MODE" != "robot" ]]; then
        echo "Starting login container (allocating resources)..." >&2
    fi
    local spawn_out
    if ! spawn_out=$(/usr/local/bin/login-spawn.sh --mode "$SESSION_MODE" --user "$TARGET_USER"); then
        echo "Unable to start ${SESSION_MODE} session: container failed to initialize." >&2
        return 1
    fi
    spawn_out=$(echo "$spawn_out" | tail -n 1)
    IFS="|" read -r JID CNODE CPORT CFP <<< "$spawn_out"
    return 0
}

run_ssh_attach() {
    local node="$1" port="$2" cfp="$3"
    shift 3

    local hk_opts=(-o "UserKnownHostsFile=/dev/null" -o "StrictHostKeyChecking=no")
    if [[ "$cfp" == *,* ]]; then
        local pub_b64="${cfp#*,}"
        if [[ -n "$pub_b64" ]]; then
            mkdir -p /run/loginbox/known_hosts 2>/dev/null || true
            chmod 700 /run/loginbox/known_hosts 2>/dev/null || true
            TEMP_KNOWN_HOSTS="/run/loginbox/known_hosts/kh.${TARGET_USER}.$$"
            printf '[%s]:%s ssh-ed25519 %s\n' "$node" "$port" "$pub_b64" > "$TEMP_KNOWN_HOSTS"
            chmod 600 "$TEMP_KNOWN_HOSTS"
            hk_opts=(-o "UserKnownHostsFile=${TEMP_KNOWN_HOSTS}" -o "StrictHostKeyChecking=yes")
        fi
    fi

    local send_env="LANG LC_*"
    if [[ -n "${SSH_ORIGINAL_COMMAND:-}" ]]; then
        send_env="LANG LC_* SSH_ORIGINAL_COMMAND"
    fi

    local ssh_base=(
        /usr/bin/ssh
        -i "$PROXY_KEY"
        -p "$port"
        -o "ConnectTimeout=2"
        "${hk_opts[@]}"
        -o "LogLevel=ERROR"
        -o "ControlMaster=no"
        -o "ControlPath=none"
        -o "PreferredAuthentications=publickey"
        -o "SendEnv=${send_env}"
    )
    if [[ $# -eq 0 ]]; then
        local flags=("${SSH_EXTRA_FLAGS[@]}")
        [[ "$IS_TTY" -eq 1 ]] && flags+=("-t")
        "${ssh_base[@]}" "${flags[@]}" "${TARGET_USER}@${node}"
        return $?
    elif [[ "${1:-}" == "-c" && $# -ge 2 ]]; then
        "${ssh_base[@]}" "${SSH_EXTRA_FLAGS[@]}" "${TARGET_USER}@${node}" "$2"
        return $?
    else
        "${ssh_base[@]}" "${SSH_EXTRA_FLAGS[@]}" "${TARGET_USER}@${node}" "$@"
        return $?
    fi
}

# Print MOTD for interactive container logins
if [[ $# -eq 0 && "$IS_TTY" -eq 1 && "$SESSION_MODE" != "robot" ]]; then
    ls -d "${USER_HOME}/." >/dev/null 2>&1 || true
    if [[ ! -f "${USER_HOME}/.hushlogin" && -f /etc/motd ]]; then
        cat /etc/motd
    fi
fi

# Hot Path: attach immediately from cached route file with zero Slurm RPCs
if [[ -r "$ROUTE_FILE" ]]; then
    IFS="|" read -r JID CNODE CPORT CFP < "$ROUTE_FILE" || true
    if [[ -n "${CNODE:-}" && -n "${CPORT:-}" ]]; then
        run_ssh_attach "$CNODE" "$CPORT" "${CFP:-}" "$@"
        rc=$?
        if [[ "$rc" -ne 255 ]]; then
            exit "$rc"
        fi
    fi
    rm -f "$ROUTE_FILE" 2>/dev/null || true
fi

# Cold / Recovery Path: discover from squeue or spawn new container job, then attach
JID=""
CNODE=""
CPORT=""
CFP=""
resolve_or_spawn || exit 1
run_ssh_attach "$CNODE" "$CPORT" "${CFP:-}" "$@"
exit $?
