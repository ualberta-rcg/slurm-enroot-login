#!/bin/bash
# /usr/local/bin/provision-ldap-user.sh
# Creates or updates LDAP user + user-private posixGroup from OIDC/CILogon claims.
set -uo pipefail
PROVISION_CALLER="ldap-user"
source /usr/local/lib/provision-common.sh

hash_from_sub() {
    local sub="$1"
    local hex
    if command -v sha256sum &>/dev/null; then
        hex=$(echo -n "${sub}" | sha256sum | awk '{print $1}')
    elif command -v shasum &>/dev/null; then
        hex=$(echo -n "${sub}" | shasum -a 256 | awk '{print $1}')
    else
        return 1
    fi
    echo "${OIDC_USER_PREFIX}${hex:0:12}"
}

# Deduplicate consecutive words and handle "Family, Given" OIDC formatting
# (e.g. "alex smith smith" -> "alex smith"; "smith, alex smith" -> "alex smith")
clean_oidc_name() {
    local name="$1"
    local family="$2"
    local hash="$3"
    local full_raw full w prev sn_candidate rest
    CLEAN_CN="$hash"
    CLEAN_SN="$hash"
    CLEAN_GIVEN="$hash"
    if [[ -z "${name}" && -z "${family}" ]]; then
        return 0
    fi
    if [[ "${name}" == *","* ]]; then
        sn_candidate=$(echo "${name}" | sed 's/,.*//' | xargs)
        rest=$(echo "${name}" | sed 's/^[^,]*,//' | xargs)
        full_raw="$rest"
    else
        sn_candidate="$family"
        full_raw=$(echo "${name} ${family}" | xargs)
    fi
    full=""
    prev=""
    for w in $full_raw; do
        if [[ "$w" != "$prev" ]]; then
            full="${full:+$full }$w"
        fi
        prev="$w"
    done
    [[ -z "$full" ]] && full="$hash"
    CLEAN_CN="$full"
    if [[ -n "$sn_candidate" ]]; then
        CLEAN_SN="$sn_candidate"
    else
        CLEAN_SN="${full##* }"
        [[ "$CLEAN_SN" == "$full" ]] && CLEAN_SN="$hash"
    fi
    CLEAN_GIVEN="${full%% *}"
    [[ -z "$CLEAN_GIVEN" || "$CLEAN_GIVEN" == "$full" ]] && CLEAN_GIVEN="$hash"
}

SUB=""
NAME=""
FAMILY=""
EMAIL=""

if [[ $# -ge 1 && "$1" != --* ]]; then
    PAYLOAD="$1"
    SUB=$(echo "${PAYLOAD}" | jq -r .sub)
    NAME=$(echo "${PAYLOAD}" | jq -r .name)
    FAMILY=$(echo "${PAYLOAD}" | jq -r .family_name)
    EMAIL=$(echo "${PAYLOAD}" | jq -r .email)
else
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --sub)     SUB="$2"; shift ;;
            --name)    NAME="$2"; shift ;;
            --family)  FAMILY="$2"; shift ;;
            --email)   EMAIL="$2"; shift ;;
        esac
        shift
    done
    SUB="${SUB:-${OIDC_SUB:-}}"
    NAME="${NAME:-${OIDC_NAME:-}}"
    FAMILY="${FAMILY:-${OIDC_FAMILY_NAME:-${OIDC_FAMILY:-}}}"
    EMAIL="${EMAIL:-${OIDC_EMAIL:-}}"
fi

[[ -z "${SUB}" ]] && { log_error "sub (OIDC subject) required"; exit 1; }

HASH=$(hash_from_sub "${SUB}") || exit 1
LDAP_PW=$(get_ldap_admin_password) || exit 1

existing=$(ldapsearch -x -H "${LDAP_HOST}" -D "${LDAP_BIND_DN}" -w "${LDAP_PW}" \
    -b "${LDAP_BASEDN}" -s sub "(uid=${HASH})" uid uidNumber -LLL 2>/dev/null | grep -c "^uid:" || true)

if [[ "${existing}" -gt 0 ]]; then
    current_given=$(ldapsearch -x -H "${LDAP_HOST}" -D "${LDAP_BIND_DN}" -w "${LDAP_PW}" \
        -b "${LDAP_BASEDN}" -s sub "(uid=${HASH})" givenName -LLL 2>/dev/null | \
        awk '/^givenName:/ {sub(/^givenName: /,""); print; exit}')
    if [[ -n "${NAME}" || -n "${FAMILY}" || -n "${EMAIL}" ]] && { [[ -z "${current_given}" ]] || [[ "${current_given}" == "${HASH}" ]]; }; then
        clean_oidc_name "${NAME}" "${FAMILY}" "${HASH}"
        MOD_FILE=$(mktemp)
        trap 'rm -f "${MOD_FILE}"' EXIT
        cat <<EOF > "${MOD_FILE}"
dn: uid=${HASH},${LDAP_BASEDN}
changetype: modify
replace: cn
cn: ${CLEAN_CN}
-
replace: sn
sn: ${CLEAN_SN}
-
replace: givenName
givenName: ${CLEAN_GIVEN}
-
replace: displayName
displayName: ${CLEAN_CN}
-
replace: mail
mail: ${EMAIL:-}
EOF
        sss_cache -u "${HASH}" 2>/dev/null || true
        ldapmodify -x -H "${LDAP_HOST}" -D "${LDAP_BIND_DN}" -w "${LDAP_PW}" -f "${MOD_FILE}" >/dev/null 2>&1 || true
        sss_cache -u "${HASH}" 2>/dev/null || true
    fi
    echo "${HASH}"
    exit 0
fi

acquire_lock "${HASH}" || exit 1
GROUP_FILE=$(mktemp)
ADD_FILE=$(mktemp)
trap 'rm -f "${GROUP_FILE}" "${ADD_FILE}"; release_lock "${HASH}"' EXIT

HIGHEST_UID=$(ldapsearch -x -H "${LDAP_HOST}" -D "${LDAP_BIND_DN}" -w "${LDAP_PW}" \
    -b "${LDAP_BASEDN}" -s sub "(objectClass=posixAccount)" uidNumber -LLL 2>/dev/null | \
    awk '/^uidNumber:/ {print $2}' | sort -n | tail -n 1)

NEXT_UID=$(( ${HIGHEST_UID:-0} + 1 ))
[[ "${NEXT_UID}" -lt "${LDAP_MIN_UID}" ]] && NEXT_UID="${LDAP_MIN_UID}"

clean_oidc_name "${NAME}" "${FAMILY}" "${HASH}"

cat <<EOF > "${GROUP_FILE}"
dn: cn=${HASH},${LDAP_GROUP_BASEDN}
objectClass: posixGroup
cn: ${HASH}
gidNumber: ${NEXT_UID}
memberUid: ${HASH}
EOF

ldapadd -x -H "${LDAP_HOST}" -D "${LDAP_BIND_DN}" -w "${LDAP_PW}" -f "${GROUP_FILE}" >/dev/null 2>&1 || true

cat <<EOF > "${ADD_FILE}"
dn: uid=${HASH},${LDAP_BASEDN}
objectClass: inetOrgPerson
objectClass: posixAccount
objectClass: shadowAccount
uid: ${HASH}
uidNumber: ${NEXT_UID}
gidNumber: ${NEXT_UID}
homeDirectory: /home/${HASH}
loginShell: /bin/bash
userPassword: {CRYPT}!
cn: ${CLEAN_CN}
sn: ${CLEAN_SN}
givenName: ${CLEAN_GIVEN}
displayName: ${CLEAN_CN}
mail: ${EMAIL:-}
employeeNumber: ${SUB}
employeeType: external
description: AuthSource=CILogon;Protocol=OIDC
EOF

if ldapadd -x -H "${LDAP_HOST}" -D "${LDAP_BIND_DN}" -w "${LDAP_PW}" -f "${ADD_FILE}" >/dev/null 2>&1; then
    sss_cache -u "${HASH}" 2>/dev/null || true
    echo "${HASH}"
    exit 0
fi

log_error "Failed to add LDAP user ${HASH}"
exit 1
