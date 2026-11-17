#!/bin/bash
# /usr/local/bin/fake_nss_group.sh
# libnss_shim group lookup hook for email-formatted OIDC usernames.
NAME="$1"
[[ "$NAME" == *@* ]] || exit 0
echo "temp:x:65535:"
