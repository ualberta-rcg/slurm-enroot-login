#!/bin/bash
# /usr/local/bin/login-spawn.sh
# Allocates a persistent login-<user>, robot-<user>, or admin-<user> Slurm
# container job using salloc + srun.
#   - login/robot run container-sshd-entrypoint as the unprivileged user.
#   - admin runs admin-container-sshd-entrypoint as Slurm UID 0 with
#     ENROOT_ALLOW_SUPERUSER, so the pod has no user namespace and sudo/su work.
#     Do not pass --container-remap-root for admin: that flag asks enroot for a
#     user-namespace uid remap and would hide every other cluster uid.
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
WAIT_TIMEOUT="${WAIT_TIMEOUT:-60}"

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
    echo "Usage: login-spawn.sh --user <username> [--mode login|robot|admin] [--node <nodename>]" >&2
    exit 1
fi

LOGINBOX_DIR="${LOGINBOX_DIR:-/etc/loginbox}"

if [[ "$MODE" == "robot" ]]; then
    PARTITION="${LOGIN_PARTITION:-login}"
    JOB_NAME="robot-${TARGET_USER}"
    CPUS="${ROBOT_CPUS:-2}"
    MEM="${ROBOT_MEM:-1G}"
    WALLTIME="${ROBOT_WALLTIME:-1-00:00:00}"
    UNIT_NAME="loginbox-robot-${TARGET_USER}"
    ROUTE_NAME="robot-${TARGET_USER}"
elif [[ "$MODE" == "admin" ]]; then
    # Root jobs are rejected when the partition sets DisableRootJobs=YES.
    PARTITION="${ADMIN_PARTITION:-${LOGIN_PARTITION:-login}}"
    JOB_NAME="admin-${TARGET_USER}"
    CPUS="${ADMIN_CPUS:-4}"
    MEM="${ADMIN_MEM:-8G}"
    WALLTIME="${ADMIN_WALLTIME:-7-00:00:00}"
    UNIT_NAME="loginbox-admin-${TARGET_USER}"
    ROUTE_NAME="admin-${TARGET_USER}"
else
    MODE="login"
    PARTITION="${LOGIN_PARTITION:-login}"
    JOB_NAME="${JOB_NAME:-login-${TARGET_USER}}"
    CPUS="${LOGIN_CPUS:-4}"
    MEM="${LOGIN_MEM:-4G}"
    WALLTIME="${LOGIN_WALLTIME:-7-00:00:00}"
    UNIT_NAME="loginbox-salloc-${TARGET_USER}"
    ROUTE_NAME="${TARGET_USER}"
fi

if [[ "$MODE" == "admin" ]]; then
    IMAGE="${ADMIN_IMAGE_PATH:-}"
    if [[ -z "$IMAGE" || ! -f "$IMAGE" ]]; then
        for candidate_img in \
            "/cache/slurm-enroot-login-admin.sqsh" \
            "/cache/slurm-enroot-login-admin-v1.sqsh"; do
            if [[ -f "$candidate_img" ]]; then
                IMAGE="$candidate_img"
                break
            fi
        done
    fi
    if [[ -z "$IMAGE" || ! -f "$IMAGE" ]]; then
        echo "ERROR: Admin container squashfs image not found (checked ADMIN_IMAGE_PATH=${ADMIN_IMAGE_PATH:-unset})." >&2
        exit 1
    fi
else
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
fi

ROUTE_DIR="/run/loginbox/routes"
LOCK_DIR="/run/loginbox/locks"
LOG_DIR="/run/loginbox/logs"
mkdir -p "$ROUTE_DIR" "$LOCK_DIR" "$LOG_DIR" 2>/dev/null || true
chmod 755 /run/loginbox "$ROUTE_DIR" 2>/dev/null || true
chmod 700 "$LOCK_DIR" 2>/dev/null || true
# 0711 allows the target UID to open its own 0600 log file while blocking directory listing
chmod 711 "$LOG_DIR" 2>/dev/null || true

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
USER_UID=""
USER_GID=""
USER_HOME=""
USER_SHELL="/bin/bash"
if [[ -n "$PW_LINE" ]]; then
    IFS=":" read -r _pw_name _pw_x USER_UID USER_GID _pw_gecos USER_HOME USER_SHELL <<< "$PW_LINE"
fi
[[ -z "$USER_HOME" ]] && USER_HOME="/home/${TARGET_USER}"
[[ -z "$USER_SHELL" ]] && USER_SHELL="/bin/bash"
if [[ "$MODE" == "admin" && ( -z "$USER_UID" || -z "$USER_GID" ) ]]; then
    echo "ERROR: unable to resolve uid/gid for admin user ${TARGET_USER}." >&2
    exit 1
fi

# Trigger autofs on USER_HOME and CVMFS without writing anything
ls -d "${USER_HOME}/." >/dev/null 2>&1 || true
ls -d /cvmfs/soft.computecanada.ca/. >/dev/null 2>&1 || true

tcp_probe() {
    local host="$1" port="$2"
    python3 -c "import socket, sys; s=socket.socket(); s.settimeout(0.15); s.connect((sys.argv[1], int(sys.argv[2]))); s.close()" "$host" "$port" >/dev/null 2>&1
}

query_login_job() {
    local owner="$TARGET_USER"
    if [[ "$MODE" == "admin" ]]; then
        # The allocation is submitted by root so every cluster uid exists in the pod.
        owner="root"
    fi
    squeue -h -u "$owner" -p "$PARTITION" -n "$JOB_NAME" -t R,PD -o "%i|%t|%N|%k" 2>/dev/null | head -n 1
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
    owner="$TARGET_USER"
    [[ "$MODE" == "admin" ]] && owner="root"
    [[ -z $(squeue -h -u "$owner" -p "$PARTITION" -n "$JOB_NAME" -t CG -o "%i" 2>/dev/null) ]] && break
    sleep 0.2
done

# 2. Build container bind mounts
build_mounts() {
    local m
    if [[ "$MODE" == "admin" ]]; then
        # Top-level shared filesystems, not the admin's own subpaths, so
        # `su - otheruser` sees that user's home, scratch, and projects.
        m="/etc/slurm,/run/munge,/cache,/cvmfs,/home"
        [[ -d /scratch ]] && m+=",/scratch"
        [[ -d /projects ]] && m+=",/projects"
        [[ -d /project ]] && m+=",/project"
        m+=",${LOGINBOX_DIR}:/etc/loginbox:ro,${LOGINBOX_DIR}:/loginbox-poc:ro"
        # Live NSS. Without the SSSD pipes, only users baked into the image resolve.
        [[ -d /var/lib/sss/pipes ]] && m+=",/var/lib/sss/pipes"
        [[ -d /var/lib/sss/mc ]] && m+=",/var/lib/sss/mc:/var/lib/sss/mc:ro"
        echo "$m"
        return
    fi

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

# Prefer the image copy unless the gateway has installed a host override,
# which is bind-mounted into the pod at /etc/loginbox.
if [[ "$MODE" == "admin" ]]; then
    ENTRYPOINT_CMD="/usr/local/bin/admin-container-sshd-entrypoint"
    if [[ -x "${LOGINBOX_DIR}/admin-container-sshd-entrypoint.sh" ]]; then
        ENTRYPOINT_CMD="/etc/loginbox/admin-container-sshd-entrypoint.sh"
    fi
else
    ENTRYPOINT_CMD="/etc/loginbox/container-sshd-entrypoint.sh"
    if [[ ! -x "${LOGINBOX_DIR}/container-sshd-entrypoint.sh" ]]; then
        ENTRYPOINT_CMD="/usr/local/bin/container-sshd-entrypoint"
    fi
fi

rm -f "$LOG_FILE" 2>/dev/null || true
touch "$LOG_FILE"
chmod 600 "$LOG_FILE"
if [[ "$MODE" != "admin" ]]; then
    chown "$TARGET_USER" "$LOG_FILE" 2>/dev/null || true
fi

# 3. Spawn persistent salloc + srun container job detached from current session
if [[ "$MODE" == "admin" && "$(id -u)" -ne 0 ]]; then
    echo "ERROR: admin root pod must be spawned by root (Slurm job UID 0 + ENROOT_ALLOW_SUPERUSER)." >&2
    exit 1
fi

SRUN_ADMIN_FLAGS=""
if [[ "$MODE" == "admin" ]]; then
    # --container-writable: overlay can receive the per-user sudoers drop-in.
    # --no-container-mount-home: do not let enroot hide /home behind one home dir.
    # ENROOT_ALLOW_SUPERUSER is read by Pyxis in slurmstepd from the step env,
    # before the container starts, so it must be exported to salloc/srun.
    SRUN_ADMIN_FLAGS="--container-writable --no-container-mount-home --container-env=ENROOT_ALLOW_SUPERUSER,LOGINBOX_SESSION_MODE,LOGINBOX_ADMIN_USER,LOGINBOX_ADMIN_UID,LOGINBOX_ADMIN_GID,LOGINBOX_ADMIN_HOME,LOGINBOX_ADMIN_SHELL"
fi

if [[ "$(id -u)" -eq 0 && "$MODE" == "admin" ]]; then
    systemctl stop "${UNIT_NAME}.service" 2>/dev/null || true
    systemctl reset-failed "${UNIT_NAME}.service" 2>/dev/null || true
    systemd-run --quiet \
        --unit="$UNIT_NAME" \
        --slice=system.slice \
        --working-directory=/tmp \
        --setenv="HOME=/root" \
        --setenv="USER=root" \
        --setenv="LOGNAME=root" \
        --setenv="ENROOT_ALLOW_SUPERUSER=yes" \
        --setenv="LOGINBOX_SESSION_MODE=admin" \
        --setenv="LOGINBOX_ADMIN_USER=${TARGET_USER}" \
        --setenv="LOGINBOX_ADMIN_UID=${USER_UID}" \
        --setenv="LOGINBOX_ADMIN_GID=${USER_GID}" \
        --setenv="LOGINBOX_ADMIN_HOME=${USER_HOME}" \
        --setenv="LOGINBOX_ADMIN_SHELL=${USER_SHELL}" \
        --property="KillMode=control-group" \
        /bin/bash -c "export ENROOT_ALLOW_SUPERUSER=yes LOGINBOX_SESSION_MODE=admin LOGINBOX_ADMIN_USER=${TARGET_USER} LOGINBOX_ADMIN_UID=${USER_UID} LOGINBOX_ADMIN_GID=${USER_GID} LOGINBOX_ADMIN_HOME=${USER_HOME@Q} LOGINBOX_ADMIN_SHELL=${USER_SHELL@Q}; exec /usr/bin/salloc -p ${PARTITION} -J ${JOB_NAME} --cpus-per-task=${CPUS} --mem=${MEM} -t ${WALLTIME} ${NODE_ARG} /usr/bin/srun --overlap --export=ALL --container-image=${IMAGE} --container-mounts=${MOUNTS} ${SRUN_ADMIN_FLAGS} ${ENTRYPOINT_CMD} </dev/null >>${LOG_FILE} 2>&1"
elif [[ "$(id -u)" -eq 0 ]]; then
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
