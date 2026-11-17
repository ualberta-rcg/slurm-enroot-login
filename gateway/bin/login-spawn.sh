#!/bin/bash
# /usr/local/bin/login-spawn.sh
# Allocates a persistent login-<user> or robot-<user> Slurm container job on
# LOGIN_PARTITION using salloc + srun, running container-sshd-entrypoint inside
# IMAGE_PATH.
#   - Uses per-job flock (/run/loginbox/locks/<job_name>.lock) + starting-job
#     wait so parallel cold connections (VS Code Remote-SSH, multi-pane SSH)
#     serialize cleanly without cancelling each other.
#   - Stores logs in 0700 /run/loginbox/logs/ (never world-readable /tmp) and
#     cleans up stuck PD jobs + transient systemd units on timeout.
set -euo pipefail

CONF_FILE="/etc/loginbox/loginbox.conf"
[[ -r "$CONF_FILE" ]] && source "$CONF_FILE"

TARGET_USER=""
TARGET_NODE=""
MODE="login"
WAIT_TIMEOUT="${WAIT_TIMEOUT:-30}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --user|-u)
            TARGET_USER="${2:-}"
            shift 2
            ;;
        --node|-w)
            TARGET_NODE="${2:-}"
            shift 2
            ;;
        --mode|-m)
            MODE="${2:-login}"
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
    echo "Usage: login-spawn.sh --user <username> [--mode login|robot] [--node <nodename>]" >&2
    exit 1
fi

PARTITION="${LOGIN_PARTITION:-login}"
LOGINBOX_DIR="${LOGINBOX_DIR:-/etc/loginbox}"

if [[ "$MODE" == "robot" ]]; then
    JOB_NAME="robot-${TARGET_USER}"
    CPUS="${ROBOT_CPUS:-2}"
    MEM="${ROBOT_MEM:-1G}"
    WALLTIME="${ROBOT_WALLTIME:-1-00:00:00}"
    UNIT_NAME="loginbox-robot-${TARGET_USER}"
    ROUTE_NAME="robot-${TARGET_USER}"
else
    MODE="login"
    JOB_NAME="${JOB_NAME:-login-${TARGET_USER}}"
    CPUS="${LOGIN_CPUS:-4}"
    MEM="${LOGIN_MEM:-4G}"
    WALLTIME="${LOGIN_WALLTIME:-7-00:00:00}"
    UNIT_NAME="loginbox-salloc-${TARGET_USER}"
    ROUTE_NAME="${TARGET_USER}"
fi

IMAGE="${IMAGE_PATH:-}"
if [[ -z "$IMAGE" || ! -f "$IMAGE" ]]; then
    for candidate_img in \
        "/cache/slurm-enroot-login-v2.sqsh" \
        "/cache/slurm-enroot-login-sshd.sqsh" \
        "/cache/slurm-enroot-login.sqsh"; do
        if [[ -f "$candidate_img" ]]; then
            IMAGE="$candidate_img"
            break
        fi
    done
fi

if [[ -z "$IMAGE" || ! -f "$IMAGE" ]]; then
    echo "ERROR: Login container squashfs image not found (checked IMAGE_PATH=${IMAGE_PATH:-unset})." >&2
    exit 1
fi

ROUTE_DIR="/run/loginbox/routes"
LOCK_DIR="/run/loginbox/locks"
LOG_DIR="/run/loginbox/logs"
mkdir -p "$ROUTE_DIR" "$LOCK_DIR" "$LOG_DIR" 2>/dev/null || true
chmod 755 /run/loginbox "$ROUTE_DIR" 2>/dev/null || true
chmod 700 "$LOCK_DIR" "$LOG_DIR" 2>/dev/null || true

ROUTE_FILE="${ROUTE_DIR}/${ROUTE_NAME}"
LOCK_FILE="${LOCK_DIR}/${JOB_NAME}.lock"
LOG_FILE="${LOG_DIR}/${JOB_NAME}.log"

# Serialize parallel cold spawns for the same job name on this gateway node
exec 9>"$LOCK_FILE"
if ! flock -w "$(( WAIT_TIMEOUT + 10 ))" 9; then
    echo "ERROR: Timed out waiting on spawn lock for ${JOB_NAME}." >&2
    exit 1
fi

PW_LINE=$(getent -s sss passwd "$TARGET_USER" 2>/dev/null || getent passwd "$TARGET_USER" 2>/dev/null || true)
USER_HOME=$(echo "$PW_LINE" | cut -d: -f6)
[[ -z "$USER_HOME" ]] && USER_HOME="/home/${TARGET_USER}"

# Trigger autofs on USER_HOME and CVMFS without writing anything
ls -d "${USER_HOME}/." >/dev/null 2>&1 || true
ls -d /cvmfs/soft.computecanada.ca/. >/dev/null 2>&1 || true

tcp_probe() {
    local host="$1" port="$2"
    python3 -c "import socket, sys; s=socket.socket(); s.settimeout(0.15); s.connect((sys.argv[1], int(sys.argv[2]))); s.close()" "$host" "$port" >/dev/null 2>&1
}

query_login_job() {
    squeue -h -u "$TARGET_USER" -p "$PARTITION" -n "$JOB_NAME" -t R,PD -o "%i|%t|%N|%k" 2>/dev/null | head -n 1
}

try_reuse_running_job() {
    local info="$1"
    local jid jstate _jnode jcomment cnode cport cfp
    IFS="|" read -r jid jstate _jnode jcomment <<< "$info"
    if [[ "$jstate" == "R" && "$jcomment" == *:*:* ]]; then
        IFS=":" read -r cnode cport cfp <<< "$jcomment"
        if [[ -z "$TARGET_NODE" || "$cnode" == "$TARGET_NODE" ]]; then
            if tcp_probe "$cnode" "$cport"; then
                echo "${jid}|${cnode}|${cport}|${cfp}" > "$ROUTE_FILE" 2>/dev/null || true
                chmod 644 "$ROUTE_FILE" 2>/dev/null || true
                echo "${jid}|${cnode}|${cport}|${cfp}"
                return 0
            fi
        fi
    fi
    return 1
}

# 1. Check if a running/starting job already exists (wait briefly if starting on peer gateway)
existing=$(query_login_job)
if [[ -n "$existing" ]]; then
    if try_reuse_running_job "$existing"; then
        exit 0
    fi
    IFS="|" read -r existing_jid existing_state existing_node existing_comment <<< "$existing"
    if [[ -z "$TARGET_NODE" || -z "$existing_node" || "$existing_node" == "$TARGET_NODE" ]]; then
        if [[ "$existing_state" == "PD" || ( "$existing_state" == "R" && -z "$existing_comment" ) ]]; then
            for _ in $(seq 1 40); do
                sleep 0.2
                existing=$(query_login_job)
                [[ -z "$existing" ]] && break
                if try_reuse_running_job "$existing"; then
                    exit 0
                fi
            done
        fi
    fi
    # Stale or wrong-node job: cancel cleanly before creating a fresh one
    existing=$(query_login_job)
    if [[ -n "$existing" ]]; then
        IFS="|" read -r stale_jid _ <<< "$existing"
        if [[ -n "$stale_jid" ]]; then
            scancel "$stale_jid" 2>/dev/null || su -s /bin/bash "$TARGET_USER" -c "scancel $stale_jid" 2>/dev/null || true
            for _ in $(seq 1 30); do
                [[ -z $(squeue -h -j "$stale_jid" 2>/dev/null) ]] && break
                sleep 0.1
            done
        fi
    fi
fi

# Wait briefly if a previous job is in Completing (CG) state
for _ in $(seq 1 25); do
    [[ -z $(squeue -h -u "$TARGET_USER" -p "$PARTITION" -n "$JOB_NAME" -t CG -o "%i" 2>/dev/null) ]] && break
    sleep 0.2
done

# 2. Build container bind mounts
build_mounts() {
    local m="/etc/slurm,/run/munge,/cache,/cvmfs,${USER_HOME},${LOGINBOX_DIR}:/etc/loginbox:ro,${LOGINBOX_DIR}:/loginbox-poc:ro"
    [[ -d "/scratch/${TARGET_USER}" ]] && m+=",/scratch/${TARGET_USER}"
    [[ -d "/projects/${TARGET_USER}" ]] && m+=",/projects/${TARGET_USER}"
    local g
    for g in $(id -Gn "$TARGET_USER" 2>/dev/null); do
        if [[ "$g" != "$TARGET_USER" ]]; then
            [[ -d "/projects/$g" ]] && m+=",/projects/$g"
            [[ -d "/project/$g" ]] && m+=",/project/$g"
        fi
    done
    echo "$m"
}

MOUNTS=$(build_mounts)
NODE_ARG=""
if [[ -n "$TARGET_NODE" ]]; then
    NODE_ARG="-w ${TARGET_NODE}"
fi

# Prefer in-image /usr/local/bin/container-sshd-entrypoint if host override isn't present
ENTRYPOINT_CMD="/etc/loginbox/container-sshd-entrypoint.sh"
if [[ ! -x "${LOGINBOX_DIR}/container-sshd-entrypoint.sh" ]]; then
    ENTRYPOINT_CMD="/usr/local/bin/container-sshd-entrypoint"
fi

rm -f "$LOG_FILE" 2>/dev/null || true
touch "$LOG_FILE"
chmod 600 "$LOG_FILE"
chown "$TARGET_USER" "$LOG_FILE" 2>/dev/null || true

# 3. Spawn persistent salloc + srun container job detached from current session
if [[ "$(id -u)" -eq 0 ]]; then
    systemctl stop "${UNIT_NAME}.service" 2>/dev/null || true
    systemctl reset-failed "${UNIT_NAME}.service" 2>/dev/null || true
    systemd-run --quiet \
        --unit="$UNIT_NAME" \
        --slice=system.slice \
        --uid="$TARGET_USER" \
        --gid="$TARGET_USER" \
        --working-directory=/tmp \
        --setenv="HOME=${USER_HOME}" \
        --setenv="USER=${TARGET_USER}" \
        --setenv="LOGNAME=${TARGET_USER}" \
        --setenv="LOGINBOX_SESSION_MODE=${MODE}" \
        --property="KillMode=control-group" \
        /bin/bash -c "exec /usr/bin/salloc -p ${PARTITION} -J ${JOB_NAME} --cpus-per-task=${CPUS} --mem=${MEM} -t ${WALLTIME} ${NODE_ARG} /usr/bin/srun --overlap --container-image=${IMAGE} --container-mounts=${MOUNTS} ${ENTRYPOINT_CMD} </dev/null >>${LOG_FILE} 2>&1"
else
    cd /tmp
    LOGINBOX_SESSION_MODE="${MODE}" nohup setsid /usr/bin/salloc -p "$PARTITION" -J "$JOB_NAME" --cpus-per-task="$CPUS" --mem="$MEM" -t "$WALLTIME" $NODE_ARG \
        /usr/bin/srun --overlap --container-image="$IMAGE" --container-mounts="$MOUNTS" \
        "$ENTRYPOINT_CMD" </dev/null >>"$LOG_FILE" 2>&1 &
fi

# 4. Poll until Slurm job Comment is populated (<node>:<port>:<fp>,<pubkey>) and TCP port is open
deadline=$(( $(date +%s) + WAIT_TIMEOUT ))
LAST_JID=""
while (( $(date +%s) < deadline )); do
    info=$(query_login_job)
    if [[ -n "$info" ]]; then
        IFS="|" read -r LAST_JID _ <<< "$info"
        if try_reuse_running_job "$info"; then
            exit 0
        fi
    fi
    sleep 0.1
done

# 5. Clean up failed/stuck job + transient systemd unit so squeue never leaks orphaned PD jobs
PENDING_REASON=""
if [[ -n "$LAST_JID" ]]; then
    PENDING_REASON=$(squeue -h -j "$LAST_JID" -o "%r" 2>/dev/null | head -n 1 || true)
    scancel "$LAST_JID" 2>/dev/null || su -s /bin/bash "$TARGET_USER" -c "scancel $LAST_JID" 2>/dev/null || true
fi
if [[ "$(id -u)" -eq 0 ]]; then
    systemctl stop "${UNIT_NAME}.service" 2>/dev/null || true
    systemctl reset-failed "${UNIT_NAME}.service" 2>/dev/null || true
fi

echo "ERROR: Timed out waiting for ${JOB_NAME} container sshd to become ready${PENDING_REASON:+ (Slurm reason: ${PENDING_REASON})}." >&2
[[ -f "$LOG_FILE" ]] && tail -n 20 "$LOG_FILE" >&2
exit 1
