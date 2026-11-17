#!/bin/bash
# /usr/local/bin/provision-truenas-home.sh
# Creates a ZFS dataset + NFS export on TrueNAS for the user's home directory
# with quota and populates /etc/skel on first login.
# Usage: provision-truenas-home.sh <username> [display_name]
#   display_name: optional display name from OIDC claims (e.g. "Jane Doe")
set -euo pipefail
PROVISION_CALLER="truenas-home"
source /usr/local/lib/provision-common.sh

user="${1:?Usage: provision-truenas-home.sh <username> [display_name]}"
DISPLAY_NAME_FROM_CALLER="${2:-}"

homedir=$(get_user_home "${user}")

if [[ -f "${homedir}/.bashrc" && -d "${homedir}/.ssh" ]]; then
    exit 0
fi

dataset=$(get_truenas_dataset_name "${homedir}")
dirname=$(basename "${homedir}")
mnt_path=$(get_truenas_mnt_path "${homedir}")
display_name=$(get_user_display_name "${user}" "${DISPLAY_NAME_FROM_CALLER}")
nfs_comment="Home: ${display_name} (${dirname})"
dataset_comment="${display_name} | ${dirname}"
nfs_comment_escaped=$(echo "${nfs_comment}" | sed 's/"/\\"/g')
quota_bytes=$(get_user_quota "${user}")

encoded_dataset=$(echo "${dataset}" | sed 's|/|%2F|g')
existing=$(truenas_api GET "/pool/dataset/id/${encoded_dataset}" "")
dataset_created=0
if ! echo "${existing}" | grep -q '"name"'; then
    result=$(truenas_api POST "/pool/dataset" "{
        \"name\": \"${dataset}\",
        \"type\": \"FILESYSTEM\",
        \"quota\": ${quota_bytes}
    }")
    if echo "${result}" | grep -q '"name"'; then
        dataset_created=1
    elif ! echo "${result}" | grep -q "already exists"; then
        log_error "Failed to create dataset ${dataset}: ${result}"
        exit 1
    fi
fi

if [[ "${dataset_created}" -eq 1 ]]; then
    truenas_api PUT "/pool/dataset/id/${encoded_dataset}" '{"snapdir": "VISIBLE"}' >/dev/null || true
    dataset_comment_escaped=$(echo "${dataset_comment}" | sed 's/"/\\"/g')
    truenas_api PUT "/pool/dataset/id/${encoded_dataset}" "{\"comments\": \"${dataset_comment_escaped}\"}" >/dev/null || true
fi

nfs_exists=$(truenas_api GET "/sharing/nfs" "")
if ! echo "${nfs_exists}" | grep -q "\"path\": \"${mnt_path}\""; then
    nfs_result=$(truenas_api POST "/sharing/nfs" "{
        \"path\": \"${mnt_path}\",
        \"comment\": \"${nfs_comment_escaped}\",
        \"networks\": ${NFS_ALLOWED_NETWORKS},
        \"hosts\": [],
        \"ro\": false,
        \"maproot_user\": \"root\",
        \"maproot_group\": \"wheel\",
        \"security\": [],
        \"enabled\": true
    }")
    if echo "${nfs_result}" | grep -q '"id"'; then
        sleep 1
        systemctl is-active --quiet autofs && systemctl reload autofs || true
    fi
fi

uid=$(id -u "${user}" 2>/dev/null) || true
gid=$(id -g "${user}" 2>/dev/null) || true

if [[ "${dataset_created}" -eq 1 && -n "${uid}" && -n "${gid}" ]]; then
    truenas_api POST "/filesystem/setperm" "{
        \"path\": \"${mnt_path}\",
        \"uid\": ${uid},
        \"gid\": ${gid},
        \"mode\": \"700\",
        \"options\": {\"recursive\": false}
    }" >/dev/null || true
fi

if ! systemctl is-active --quiet autofs; then
    systemctl start autofs || true
    sleep 1
fi

for _ in 1 2 3 4 5; do
    [[ -d "${homedir}" ]] && ls "${homedir}/" &>/dev/null && break
    sleep 1
done

if [[ -d "${homedir}" && ! -f "${homedir}/.bashrc" && -d /etc/skel ]]; then
    cp -a /etc/skel/. "${homedir}/" 2>/dev/null || true
    [[ -n "${uid}" && -n "${gid}" ]] && chown -R "${uid}:${gid}" "${homedir}"
fi

exit 0
