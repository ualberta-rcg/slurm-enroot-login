#!/bin/bash
# /usr/local/lib/provision-common.sh
# Common functions for dynamic SSH + Open OnDemand user provisioning.
# Sourced by all provisioning scripts; reads site overrides from /etc/loginbox/provisioning.conf.

[[ -r /etc/loginbox/provisioning.conf ]] && source /etc/loginbox/provisioning.conf

PROVISION_LOG="${PROVISION_LOG:-/var/log/user-provision.log}"
TRUENAS_HOST="${TRUENAS_HOST:-https://storage.internal.example.org}"
TRUENAS_API_KEY_FILE="${TRUENAS_API_KEY_FILE:-/etc/truenas/api_key}"
TRUENAS_POOL="${TRUENAS_POOL:-tank/home}"
TRUENAS_MNT="${TRUENAS_MNT:-/mnt/tank/home}"
QUOTA_DEFAULT="${QUOTA_DEFAULT:-5368709120}"
NFS_ALLOWED_NETWORKS="${NFS_ALLOWED_NETWORKS:-[\"192.0.2.0/24\"]}"
NFS_EXPOSE_SNAPSHOTS="${NFS_EXPOSE_SNAPSHOTS:-true}"
SLURM_DEFAULT_ACCOUNT="${SLURM_DEFAULT_ACCOUNT:-main}"

LDAP_HOST="${LDAP_HOST:-ldap://ldap.internal.example.org:389}"
LDAP_BASEDN="${LDAP_BASEDN:-ou=People,dc=cluster,dc=example,dc=org}"
LDAP_GROUP_BASEDN="${LDAP_GROUP_BASEDN:-ou=Group,dc=cluster,dc=example,dc=org}"
LDAP_BIND_DN="${LDAP_BIND_DN:-cn=admin,dc=cluster,dc=example,dc=org}"
LDAP_ADMIN_PASSWORD_FILE="${LDAP_ADMIN_PASSWORD_FILE:-/etc/loginbox/ldap_admin_password}"
LDAP_MIN_UID="${LDAP_MIN_UID:-50000}"
OIDC_USER_PREFIX="${OIDC_USER_PREFIX:-clg_}"

get_ldap_admin_password() {
    if [[ -n "${LDAP_ADMIN_PASSWORD:-}" ]]; then
        echo "${LDAP_ADMIN_PASSWORD}"
        return 0
    fi
    if [[ -f "${LDAP_ADMIN_PASSWORD_FILE}" ]]; then
        cat "${LDAP_ADMIN_PASSWORD_FILE}"
        return 0
    fi
    log_error "LDAP admin password not found (set LDAP_ADMIN_PASSWORD or ${LDAP_ADMIN_PASSWORD_FILE})"
    return 1
}

log() {
    local level="$1"; shift
    local msg="$*"
    local ts
    ts=$(date '+%Y-%m-%d %H:%M:%S')
    local caller="${PROVISION_CALLER:-unknown}"
    echo "${ts} [${level}] [${caller}] ${msg}" >> "${PROVISION_LOG}"
    echo "${ts} [${level}] ${msg}" >&2
}

log_info()  { log INFO  "$@"; }
log_warn()  { log WARN  "$@"; }
log_error() { log ERROR "$@"; }
log_debug() { log DEBUG "$@"; }

get_truenas_api_key() {
    if [[ ! -f "${TRUENAS_API_KEY_FILE}" ]]; then
        log_error "TrueNAS API key file not found: ${TRUENAS_API_KEY_FILE}"
        return 1
    fi
    cat "${TRUENAS_API_KEY_FILE}"
}

truenas_api() {
    local method="$1"
    local endpoint="$2"
    local data="$3"
    local api_key
    api_key=$(get_truenas_api_key) || return 1

    local args=( -s -k -X "${method}"
                 -H "Authorization: Bearer ${api_key}"
                 -H "Content-Type: application/json"
                 "${TRUENAS_HOST}/api/v2.0${endpoint}" )

    if [[ -n "${data}" ]]; then
        args+=( -d "${data}" )
    fi

    curl "${args[@]}" 2>/dev/null
}

get_user_quota() {
    echo "${QUOTA_DEFAULT}"
}

get_user_home() {
    local user="$1"
    local homedir
    homedir=$(getent -s sss passwd "${user}" 2>/dev/null | cut -d: -f6 || getent passwd "${user}" 2>/dev/null | cut -d: -f6 || true)
    if [[ -n "${homedir}" ]]; then
        echo "${homedir}"
        return 0
    fi
    echo "/home/${user}"
}

get_truenas_dataset_name() {
    local homedir="$1"
    local basename
    basename=$(basename "${homedir}")
    echo "${TRUENAS_POOL}/${basename}"
}

get_truenas_mnt_path() {
    local homedir="$1"
    local basename
    basename=$(basename "${homedir}")
    echo "${TRUENAS_MNT}/${basename}"
}

get_user_display_name() {
    local user="$1"
    local display_name="${2:-}"
    if [[ -n "${display_name}" ]]; then
        echo "${display_name}"
        return 0
    fi
    if [[ "${user}" != "${OIDC_USER_PREFIX}"* ]]; then
        echo "${user}"
        return 0
    fi
    local ldap_pw
    ldap_pw=$(get_ldap_admin_password 2>/dev/null) || { echo "${user}"; return 0; }
    local cn
    cn=$(ldapsearch -x -H "${LDAP_HOST}" -D "${LDAP_BIND_DN}" -w "${ldap_pw}" \
        -b "${LDAP_BASEDN}" -s sub "(uid=${user})" displayName cn -LLL 2>/dev/null | \
        awk '/^displayName:|^cn:/ {gsub(/^[^:]+: /,""); print; exit}' || true)
    if [[ -n "${cn}" ]]; then
        echo "${cn}"
    else
        echo "${user}"
    fi
}

LOCK_DIR="/run/lock/provision"

acquire_lock() {
    local user="$1"
    mkdir -p "${LOCK_DIR}"
    local lockfile="${LOCK_DIR}/${user}.lock"
    exec 200>"${lockfile}"
    if ! flock -n 200; then
        log_info "Another provisioning process running for ${user}, skipping"
        return 1
    fi
    return 0
}

release_lock() {
    local user="$1"
    local lockfile="${LOCK_DIR}/${user}.lock"
    flock -u 200 2>/dev/null || true
    rm -f "${lockfile}" 2>/dev/null || true
}
