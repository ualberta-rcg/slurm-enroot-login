#!/bin/bash
# /usr/local/bin/cilogon-add-ldap.sh
# Wrapper invoked by pam_oauth2_device provision.exec with JSON payload as $1.
exec /usr/local/bin/provision-ldap-user.sh "$@"
