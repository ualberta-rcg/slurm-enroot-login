#!/bin/bash
# /usr/local/bin/provision-ood-email.sh
# Saves the user's OIDC email claim into ~/ondemand/oidc_email.txt for Open OnDemand.
set -euo pipefail
PROVISION_CALLER="ood-email"
source /usr/local/lib/provision-common.sh

user="${1:?Usage: provision-ood-email.sh <username> <email>}"
email="${2:-}"
[[ -z "${email}" ]] && exit 0

homedir=$(get_user_home "${user}")
[[ ! -d "${homedir}" ]] && exit 1

ood_dir="${homedir}/ondemand"
email_file="${ood_dir}/oidc_email.txt"

mkdir -p "${ood_dir}"
echo "${email}" > "${email_file}"

uid=$(id -u "${user}" 2>/dev/null) || true
gid=$(id -g "${user}" 2>/dev/null) || true
if [[ -n "${uid}" && -n "${gid}" ]]; then
    chown "${uid}:${gid}" "${ood_dir}" "${email_file}"
    chmod 700 "${ood_dir}"
    chmod 600 "${email_file}"
fi
exit 0
