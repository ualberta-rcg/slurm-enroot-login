#!/usr/bin/env bats
# BATS test suite for login-gateway/etc/enroot/hooks.d/50-login-pod-hostname.sh

setup() {
    REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
    HOOK="${REPO_ROOT}/login-gateway/etc/enroot/hooks.d/50-login-pod-hostname.sh"
    WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/login-pod-hook-bats.XXXXXX")"
    mkdir -p "${WORK_DIR}/rootfs/etc" "${WORK_DIR}/runtime" "${WORK_DIR}/state/pod-hostname"
    echo "slurm-login-pods test" > "${WORK_DIR}/rootfs/etc/slurm-login-pods-release"
    printf '50001 50001 1\n' > "${WORK_DIR}/uid_map_userns"
    printf '0 0 4294967295\n' > "${WORK_DIR}/uid_map_host"
    ln -s "uts:[4026532999]" "${WORK_DIR}/uts_pod"
    ln -s "uts:[4026531838]" "${WORK_DIR}/uts_init"
    : > "${WORK_DIR}/mounts"
    : > "${WORK_DIR}/environ"
}

teardown() {
    rm -rf "${WORK_DIR}"
}

@test "refuses to act in host initial user namespace (count=4294967295)" {
    run env \
        LOGIN_POD_HOOK_TEST_MODE=1 \
        LOGIN_POD_HOOK_UID_MAP="${WORK_DIR}/uid_map_host" \
        LOGIN_POD_HOOK_SELF_UTS="${WORK_DIR}/uts_pod" \
        LOGIN_POD_HOOK_INIT_UTS="${WORK_DIR}/uts_init" \
        LOGIN_POD_HOOK_RECORD_FILE="${WORK_DIR}/recorded_hostname" \
        ENROOT_ROOTFS="${WORK_DIR}/rootfs" \
        ENROOT_RUNTIME_PATH="${WORK_DIR}/runtime" \
        ENROOT_MOUNTS="${WORK_DIR}/mounts" \
        LOGIN_GATEWAY_POD_HOSTNAME="cluster-login-alice" \
        "$HOOK"
    [ "$status" -eq 0 ]
    [ ! -f "${WORK_DIR}/recorded_hostname" ]
    [ ! -s "${WORK_DIR}/mounts" ]
}

@test "refuses to act when UTS namespace matches PID 1" {
    run env \
        LOGIN_POD_HOOK_TEST_MODE=1 \
        LOGIN_POD_HOOK_UID_MAP="${WORK_DIR}/uid_map_userns" \
        LOGIN_POD_HOOK_SELF_UTS="${WORK_DIR}/uts_init" \
        LOGIN_POD_HOOK_INIT_UTS="${WORK_DIR}/uts_init" \
        LOGIN_POD_HOOK_RECORD_FILE="${WORK_DIR}/recorded_hostname" \
        ENROOT_ROOTFS="${WORK_DIR}/rootfs" \
        ENROOT_RUNTIME_PATH="${WORK_DIR}/runtime" \
        ENROOT_MOUNTS="${WORK_DIR}/mounts" \
        LOGIN_GATEWAY_POD_HOSTNAME="cluster-login-alice" \
        "$HOOK"
    [ "$status" -eq 0 ]
    [ ! -f "${WORK_DIR}/recorded_hostname" ]
    [ ! -s "${WORK_DIR}/mounts" ]
}

@test "skips ordinary non-login-pod containers lacking release sentinel" {
    rm -f "${WORK_DIR}/rootfs/etc/slurm-login-pods-release"
    run env \
        LOGIN_POD_HOOK_TEST_MODE=1 \
        LOGIN_POD_HOOK_UID_MAP="${WORK_DIR}/uid_map_userns" \
        LOGIN_POD_HOOK_SELF_UTS="${WORK_DIR}/uts_pod" \
        LOGIN_POD_HOOK_INIT_UTS="${WORK_DIR}/uts_init" \
        LOGIN_POD_HOOK_RECORD_FILE="${WORK_DIR}/recorded_hostname" \
        ENROOT_ROOTFS="${WORK_DIR}/rootfs" \
        ENROOT_RUNTIME_PATH="${WORK_DIR}/runtime" \
        ENROOT_MOUNTS="${WORK_DIR}/mounts" \
        LOGIN_GATEWAY_POD_HOSTNAME="cluster-login-alice" \
        "$HOOK"
    [ "$status" -eq 0 ]
    [ ! -f "${WORK_DIR}/recorded_hostname" ]
}

@test "sets UTS hostname and writes /etc/hostname + /etc/hosts mounts in unshared userns" {
    run env \
        LOGIN_POD_HOOK_TEST_MODE=1 \
        LOGIN_POD_HOOK_UID_MAP="${WORK_DIR}/uid_map_userns" \
        LOGIN_POD_HOOK_SELF_UTS="${WORK_DIR}/uts_pod" \
        LOGIN_POD_HOOK_INIT_UTS="${WORK_DIR}/uts_init" \
        LOGIN_POD_HOOK_RECORD_FILE="${WORK_DIR}/recorded_hostname" \
        ENROOT_ROOTFS="${WORK_DIR}/rootfs" \
        ENROOT_RUNTIME_PATH="${WORK_DIR}/runtime" \
        ENROOT_MOUNTS="${WORK_DIR}/mounts" \
        LOGIN_GATEWAY_POD_HOSTNAME="cluster-login-alice" \
        "$HOOK"
    [ "$status" -eq 0 ]
    [ "$(cat "${WORK_DIR}/recorded_hostname")" = "cluster-login-alice" ]
    grep -q "/etc/hostname none" "${WORK_DIR}/mounts"
    grep -q "/etc/hosts none" "${WORK_DIR}/mounts"
    hosts_src="$(awk '/\/etc\/hosts none/{print $1}' "${WORK_DIR}/mounts")"
    grep -q $'127.0.1.1\tcluster-login-alice' "$hosts_src"
}

@test "rejects invalid RFC-1123 hostnames" {
    for bad in "-leading" "trailing-" "bad_underscore" "bad;cmd"; do
        run env \
            LOGIN_POD_HOOK_TEST_MODE=1 \
            LOGIN_POD_HOOK_UID_MAP="${WORK_DIR}/uid_map_userns" \
            LOGIN_POD_HOOK_SELF_UTS="${WORK_DIR}/uts_pod" \
            LOGIN_POD_HOOK_INIT_UTS="${WORK_DIR}/uts_init" \
            LOGIN_POD_HOOK_RECORD_FILE="${WORK_DIR}/recorded_hostname" \
            ENROOT_ROOTFS="${WORK_DIR}/rootfs" \
            ENROOT_RUNTIME_PATH="${WORK_DIR}/runtime" \
            ENROOT_MOUNTS="${WORK_DIR}/mounts" \
            LOGIN_GATEWAY_POD_HOSTNAME="$bad" \
            "$HOOK"
        [ "$status" -eq 0 ]
        [ ! -f "${WORK_DIR}/recorded_hostname" ]
    done
}
