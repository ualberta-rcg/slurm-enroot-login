#!/bin/bash
# /usr/local/bin/provision-slurm-user.sh
# Ensures the user has a Slurm accounting association under SLURM_DEFAULT_ACCOUNT.
set -euo pipefail
PROVISION_CALLER="slurm-user"
source /usr/local/lib/provision-common.sh

user="${1:?Usage: provision-slurm-user.sh <username>}"
acct=$(sacctmgr list assoc user="${user}" account="${SLURM_DEFAULT_ACCOUNT}" -nP 2>/dev/null || true)

if [[ -z "${acct}" ]]; then
    if sacctmgr create user name="${user}" account="${SLURM_DEFAULT_ACCOUNT}" -i > /dev/null 2>&1; then
        scontrol reconfigure 2>/dev/null || true
    else
        log_error "Failed to create Slurm user ${user}"
        exit 1
    fi
fi
exit 0
