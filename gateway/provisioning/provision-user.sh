#!/bin/bash
# /usr/local/bin/provision-user.sh
# PAM open_session user provisioning orchestrator for SSH logins.
set -uo pipefail

user="${PAM_USER:?PAM_USER not set}"

if [[ "${PAM_TYPE:-open_session}" == "close_session" ]]; then
    rm -f "/run/loginbox/pam-session/pid.${PPID}" 2>/dev/null || true
    exit 0
fi

case "${user}" in
    root|munge|slurm|sshd|ubuntu|cilogon|nobody|www-data)
        exit 0
        ;;
esac

mkdir -p /run/loginbox/pam-session /run/loginbox/provisioned 2>/dev/null || true
chmod 755 /run/loginbox /run/loginbox/pam-session /run/loginbox/provisioned 2>/dev/null || true
echo "${user}" > "/run/loginbox/pam-session/pid.${PPID}" 2>/dev/null || true
chmod 644 "/run/loginbox/pam-session/pid.${PPID}" 2>/dev/null || true

uid=$(id -u "${user}" 2>/dev/null) || exit 0
if (( uid < 10000 )); then
    exit 0
fi

LOCAL_STAMP="/run/loginbox/provisioned/${user}"
SHARED_STAMP_DIR="/cache/loginbox/provisioned"
SHARED_STAMP="${SHARED_STAMP_DIR}/${user}"
USER_HOME="/home/${user}"

if [[ ( -f "${LOCAL_STAMP}" || -f "${SHARED_STAMP}" ) && -f "${USER_HOME}/.ssh/id_ed25519" && -f "${USER_HOME}/.ssh/authorized_keys" ]]; then
    [[ -f "${LOCAL_STAMP}" ]] || touch "${LOCAL_STAMP}" 2>/dev/null || true
    exit 0
fi

PROVISION_CALLER="provision-user-pam"
source /usr/local/lib/provision-common.sh

log_info "=== PAM provisioning triggered for user=${user} uid=${uid} ==="

acquire_lock "${user}" || exit 0
trap 'release_lock "${user}"' EXIT

home_ok=0
slurm_ok=0
keys_ok=0

if [[ -f "${USER_HOME}/.bashrc" && -d "${USER_HOME}/.ssh" ]]; then
    home_ok=1
else
    if /usr/local/bin/provision-truenas-home.sh "${user}"; then
        home_ok=1
    else
        log_error "Home provisioning failed for ${user} (continuing to Slurm)"
    fi
fi

if [[ -f "${LOCAL_STAMP}" || -f "${SHARED_STAMP}" ]]; then
    slurm_ok=1
else
    if /usr/local/bin/provision-slurm-user.sh "${user}"; then
        slurm_ok=1
    else
        log_error "Slurm provisioning failed for ${user}"
    fi
fi

if [[ -f "${USER_HOME}/.ssh/id_ed25519" && -f "${USER_HOME}/.ssh/authorized_keys" ]]; then
    keys_ok=1
else
    if /usr/local/bin/provision-ssh-keys.sh "${user}"; then
        keys_ok=1
    else
        log_error "SSH key provisioning failed for ${user}"
    fi
fi

if [[ "${home_ok}" -eq 1 && "${slurm_ok}" -eq 1 && "${keys_ok}" -eq 1 ]]; then
    touch "${LOCAL_STAMP}" 2>/dev/null || true
    mkdir -p "${SHARED_STAMP_DIR}" 2>/dev/null || true
    touch "${SHARED_STAMP}" 2>/dev/null || true
fi

log_info "=== PAM provisioning complete for user=${user} ==="
exit 0
