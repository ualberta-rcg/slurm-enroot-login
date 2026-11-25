#!/usr/bin/env bash
# /etc/enroot/hooks.d/50-login-pod-hostname.sh — per-user hostname for rootless login pods
#
# Rootless pods get a UTS namespace owned by enroot's user namespace, so only
# a hook (which still holds capabilities in that namespace) can set the pod
# hostname; the unprivileged entrypoint cannot. Admin pods run as real root
# and set their own hostname, so this hook skips them.
#
# Hostname source, first match wins:
#   1. LOGIN_GATEWAY_POD_HOSTNAME in the hook environment
#   2. LOGIN_GATEWAY_POD_HOSTNAME in ${ENROOT_ENVIRON}
#   3. /run/login-gateway/pod-hostname/<uid> written by spawn (root-owned)
# Only acts on slurm-login-pods images (release sentinel present), so
# ordinary container jobs are never renamed.

set -eu

hook_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
uid_map_file="/proc/self/uid_map"
self_uts_link="/proc/self/ns/uts"
init_uts_link="/proc/1/ns/uts"
hostname_bin="/usr/bin/hostname"
[ -x "${hostname_bin}" ] || hostname_bin="hostname"
state_bases=("/run/login-gateway" "/run/loginbox")
expected_state_uid="0"
test_record_file=""

# Allow unit-test fixtures ONLY when running outside /etc/enroot/hooks.d
if [ "${hook_dir}" != "/etc/enroot/hooks.d" ] && [ "${LOGIN_POD_HOOK_TEST_MODE:-0}" = "1" ]; then
    uid_map_file="${LOGIN_POD_HOOK_UID_MAP:-${uid_map_file}}"
    self_uts_link="${LOGIN_POD_HOOK_SELF_UTS:-${self_uts_link}}"
    init_uts_link="${LOGIN_POD_HOOK_INIT_UTS:-${init_uts_link}}"
    test_record_file="${LOGIN_POD_HOOK_RECORD_FILE:-}"
    expected_state_uid="${LOGIN_POD_HOOK_EXPECTED_OWNER_UID:-0}"
    if [ -n "${LOGIN_POD_HOOK_STATE_DIR:-}" ]; then
        state_bases=("${LOGIN_POD_HOOK_STATE_DIR}")
    fi
fi

read -r _inside outside count < "${uid_map_file}"
# Identity map of the whole range means the initial user namespace: never
# touch the host's UTS namespace.
[ "${count}" = "4294967295" ] && exit 0
[ -f "${ENROOT_ROOTFS-}/etc/slurm-login-pods-release" ] || exit 0

pod_hostname="${LOGIN_GATEWAY_POD_HOSTNAME-}"
if [ -z "${pod_hostname}" ] && [ -n "${ENROOT_ENVIRON-}" ] && [ -r "${ENROOT_ENVIRON}" ]; then
    pod_hostname=$(sed -n 's/^LOGIN_GATEWAY_POD_HOSTNAME=//p' "${ENROOT_ENVIRON}" | tail -n 1 | tr -d "\"'")
fi
if [ -z "${pod_hostname}" ]; then
    for base in "${state_bases[@]}"; do
        f="${base}/pod-hostname/${outside}"
        if [ -f "${f}" ] && [ ! -L "${f}" ] && [ "$(stat -c %u "${f}")" = "${expected_state_uid}" ]; then
            pod_hostname=$(head -n 1 "${f}")
            break
        fi
    done
fi
[ -n "${pod_hostname}" ] || exit 0

case "${pod_hostname}" in
    *[!a-z0-9-]*|-*|*-) exit 0 ;;
esac
[ "${#pod_hostname}" -le 63 ] || exit 0

self_uts="$(readlink "${self_uts_link}" 2>/dev/null || true)"
init_uts="$(readlink "${init_uts_link}" 2>/dev/null || true)"
if [ -z "${self_uts}" ] || [ "${self_uts}" = "${init_uts}" ]; then
    exit 0
fi

if [ -n "${test_record_file}" ]; then
    printf '%s\n' "${pod_hostname}" > "${test_record_file}"
else
    "${hostname_bin}" "${pod_hostname}" 2>/dev/null || exit 0
fi

etc_dir=$(mktemp -d "${ENROOT_RUNTIME_PATH:-/tmp}/pod-etc.XXXXXX")
printf '%s\n' "${pod_hostname}" > "${etc_dir}/hostname"
{
    grep -v -w -e "${pod_hostname}" /etc/hosts 2>/dev/null || true
    printf '127.0.1.1\t%s\n' "${pod_hostname}"
} > "${etc_dir}/hosts"
chmod 0644 "${etc_dir}/hostname" "${etc_dir}/hosts"

if [ -n "${ENROOT_MOUNTS-}" ]; then
    printf '%s /etc/hostname none x-create=file,bind,ro,nosuid,nodev,noexec,private\n' "${etc_dir}/hostname" >> "${ENROOT_MOUNTS}"
    printf '%s /etc/hosts none x-create=file,bind,ro,nosuid,nodev,noexec,private\n' "${etc_dir}/hosts" >> "${ENROOT_MOUNTS}"
fi
