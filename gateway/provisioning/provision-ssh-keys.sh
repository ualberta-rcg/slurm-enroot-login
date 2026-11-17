#!/bin/bash
# /usr/local/bin/provision-ssh-keys.sh
# Generates an internal cluster Ed25519 SSH keypair for the user if absent and
# authorizes it in ~/.ssh/authorized_keys (used by Open OnDemand Shell & MPI/inter-node SSH).
set -euo pipefail
PROVISION_CALLER="ssh-keys"
source /usr/local/lib/provision-common.sh

user="${1:?Usage: provision-ssh-keys.sh <username>}"
homedir=$(get_user_home "${user}")
ssh_dir="${homedir}/.ssh"
key_file="${ssh_dir}/id_ed25519"
auth_keys="${ssh_dir}/authorized_keys"

uid=$(id -u "${user}" 2>/dev/null) || exit 1
gid=$(id -g "${user}" 2>/dev/null) || exit 1

if [[ ! -d "${ssh_dir}" ]]; then
    mkdir -p "${ssh_dir}"
    chown "${uid}:${gid}" "${ssh_dir}"
    chmod 0700 "${ssh_dir}"
fi

if [[ ! -f "${key_file}" ]]; then
    ssh-keygen -t ed25519 -f "${key_file}" -N "" -C "${user}@cluster-internal" > /dev/null 2>&1
    chown "${uid}:${gid}" "${key_file}" "${key_file}.pub"
    chmod 0600 "${key_file}"
    chmod 0644 "${key_file}.pub"
fi

pubkey=$(cat "${key_file}.pub")
if [[ ! -f "${auth_keys}" ]]; then
    echo "${pubkey}" > "${auth_keys}"
    chown "${uid}:${gid}" "${auth_keys}"
    chmod 0600 "${auth_keys}"
elif ! grep -qF "${pubkey}" "${auth_keys}"; then
    echo "${pubkey}" >> "${auth_keys}"
fi
exit 0
