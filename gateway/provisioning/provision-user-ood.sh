#!/bin/bash
# /usr/local/bin/provision-user-ood.sh
# Open OnDemand PUN pre-hook (pun_pre_hook_root_cmd) for user provisioning.
set -uo pipefail
PROVISION_CALLER="provision-user-ood"
source /usr/local/lib/provision-common.sh

OOD_USER=""
while [[ "$#" -gt 0 ]]; do
    case "$1" in
        --user) OOD_USER="$2"; shift ;;
    esac
    shift
done

user="${OOD_USER:?--user argument required}"

OIDC_SUB="${OOD_OIDC_CLAIM_sub:-}"
OIDC_NAME="${OOD_OIDC_CLAIM_name:-}"
OIDC_FAMILY_NAME="${OOD_OIDC_CLAIM_family_name:-}"
OIDC_EMAIL="${OOD_OIDC_CLAIM_email:-}"

if [[ -n "${OIDC_SUB}" ]]; then
    canonical=$(OIDC_SUB="${OIDC_SUB}" OIDC_NAME="${OIDC_NAME}" \
        OIDC_FAMILY_NAME="${OIDC_FAMILY_NAME}" OIDC_EMAIL="${OIDC_EMAIL}" \
        /usr/local/bin/provision-ldap-user.sh 2>/dev/null) || {
        log_error "Failed to create/find LDAP user for sub=${OIDC_SUB}"
        exit 1
    }
    user="${canonical}"
    for i in {1..10}; do
        getent passwd "${user}" >/dev/null 2>&1 && break
        sleep 1
    done
fi

uid=$(id -u "${user}" 2>/dev/null) || {
    log_error "Cannot resolve user ${user}"
    exit 1
}
if (( uid < LDAP_MIN_UID )); then
    exit 0
fi

log_info "=== OOD provisioning triggered for user=${user} uid=${uid} ==="

acquire_lock "${user}" || exit 0
trap 'release_lock "${user}"' EXIT

OOD_DISPLAY_NAME=""
if [[ -n "${OIDC_NAME}" || -n "${OIDC_FAMILY_NAME}" ]]; then
    OOD_DISPLAY_NAME=$(echo "${OIDC_NAME} ${OIDC_FAMILY_NAME}" | xargs)
fi
/usr/local/bin/provision-truenas-home.sh "${user}" "${OOD_DISPLAY_NAME}" || log_error "Home provisioning failed for ${user}"
/usr/local/bin/provision-slurm-user.sh "${user}" || log_error "Slurm provisioning failed for ${user}"
/usr/local/bin/provision-ssh-keys.sh "${user}" || log_error "SSH key provisioning failed for ${user}"

if [[ -n "${OIDC_EMAIL}" ]]; then
    /usr/local/bin/provision-ood-email.sh "${user}" "${OIDC_EMAIL}" || log_error "OIDC email save failed for ${user}"
fi

log_info "=== OOD provisioning complete for user=${user} ==="
exit 0
