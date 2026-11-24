#!/bin/bash
# /usr/local/bin/enter-login-container.sh
# Optional direct-srun / nsenter helper for attaching into a running login
# container's user + mount namespaces when not using in-container sshd.
set -uo pipefail

JID="${SLURM_JOB_ID:-}"
if [[ -z "$JID" ]]; then
    echo "ERROR: enter-login-container.sh must run inside a Slurm job step (SLURM_JOB_ID unset)." >&2
    exit 1
fi

SELF_CG=$(awk -F: '$1 == "0" {print $3}' /proc/self/cgroup 2>/dev/null || true)
JOB_CG_DIR="/sys/fs/cgroup${SELF_CG%/step_*}"
if [[ ! -d "$JOB_CG_DIR" ]]; then
    JOB_CG_DIR="/sys/fs/cgroup/system.slice/slurmstepd.scope/job_${JID}"
fi

CPID=""
HOST_MNT_NS=$(readlink /proc/1/ns/mnt 2>/dev/null || true)

for _ in {1..100}; do
    if [[ -d "$JOB_CG_DIR" ]]; then
        for cg_procs in "$JOB_CG_DIR"/step_*/user/task_*/cgroup.procs; do
            [[ -r "$cg_procs" ]] || continue
            while read -r p; do
                [[ -z "$p" ]] && continue
                p_mnt=$(readlink "/proc/$p/ns/mnt" 2>/dev/null || true)
                if [[ -n "$p_mnt" && "$p_mnt" != "$HOST_MNT_NS" ]]; then
                    if grep -q enroot "/proc/$p/mountinfo" 2>/dev/null && [[ -f "/proc/$p/root/tmp/.login_container_ready" ]]; then
                        CPID="$p"
                        break 3
                    fi
                fi
            done < "$cg_procs"
        done
    fi
    sleep 0.2
done

if [[ -z "$CPID" ]]; then
    echo "ERROR: Login container failed to initialize for job ${JID}. Refusing to open an uncontained host shell." >&2
    exit 1
fi

exec /usr/bin/nsenter --target "$CPID" --user --preserve-credentials --mount --wdns \
    /bin/bash -c '
        if ! grep -q enroot /proc/self/mountinfo 2>/dev/null; then
            echo "ERROR: Container containment verification failed." >&2
            exit 1
        fi
        exec /usr/local/bin/login-shell "$@"
    ' -- "$@"
