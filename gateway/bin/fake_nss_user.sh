#!/bin/bash
# /usr/local/bin/fake_nss_user.sh
# libnss_shim passwd lookup hook: maps non-local SSH users inside ssh.service
# to the unprivileged 'cilogon' shim account whose shell is login-helper.sh.
CG=$(cat /proc/self/cgroup)
[[ "$CG" == *ssh.service ]] || exit 0
echo "cilogon:x:3000:3000:CILogon User:/local/home/cilogon:/usr/local/bin/login-helper.sh"
