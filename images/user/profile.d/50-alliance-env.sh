# /etc/profile.d/50-alliance-env.sh
# Alliance login-node environment parity inside slurm-login-pods:
#   - Defines CC_CLUSTER, SCRATCH, and PROJECT environment variables.
#   - Ensures ~/scratch and ~/projects/<group> convenience symlinks exist.
#   - Guarantees a 0700 XDG_RUNTIME_DIR in /tmp when missing or world-readable.
#   - Warns interactive users when their login pod has < 6 hours remaining.

export CC_CLUSTER="${CC_CLUSTER:-cluster}"

# Login pod rootfs is read-only SquashFS: disable background CLI self-updaters
if [ "${LOGIN_SESSION_MODE:-}" != "robot" ]; then
    export DISABLE_AUTOUPDATER=1
    export AGY_CLI_DISABLE_AUTO_UPDATE=true
fi

_slp_uid="$(id -u 2>/dev/null || echo 0)"
_slp_user="$(id -un 2>/dev/null || echo "${USER:-}")"

if [ "${_slp_uid:-0}" -ge 1000 ] && [ -n "${_slp_user}" ]; then
    # Private 0700 XDG_RUNTIME_DIR inside /tmp when unset or not user-owned 0700
    if [ -z "${XDG_RUNTIME_DIR:-}" ] || [ ! -d "${XDG_RUNTIME_DIR}" ] || [ ! -O "${XDG_RUNTIME_DIR}" ]; then
        _slp_rt="/tmp/run-${_slp_uid}"
        mkdir -p "${_slp_rt}" 2>/dev/null && chmod 700 "${_slp_rt}" 2>/dev/null && export XDG_RUNTIME_DIR="${_slp_rt}"
        unset _slp_rt
    fi

    if [ -d "/scratch/${_slp_user}" ]; then
        export SCRATCH="/scratch/${_slp_user}"
    fi

    for _slp_g in ${_slp_user} $(id -Gn 2>/dev/null); do
        for _slp_base in /projects /project; do
            if [ -d "${_slp_base}/${_slp_g}" ]; then
                [ -z "${PROJECT:-}" ] && export PROJECT="${_slp_base}/${_slp_g}"
            fi
        done
    done
    unset _slp_g _slp_base

    # Convenience symlinks in $HOME on interactive non-robot sessions
    if [ "${LOGIN_SESSION_MODE:-login}" != "robot" ] && [ -n "${HOME:-}" ] && [ -d "${HOME}" ] && [ -w "${HOME}" ]; then
        if [ -n "${SCRATCH:-}" ] && [ ! -e "${HOME}/scratch" ] && [ ! -L "${HOME}/scratch" ]; then
            ln -s "${SCRATCH}" "${HOME}/scratch" 2>/dev/null || true
        fi
        for _slp_g in ${_slp_user} $(id -Gn 2>/dev/null); do
            for _slp_base in /projects /project; do
                if [ -d "${_slp_base}/${_slp_g}" ]; then
                    mkdir -p "${HOME}/projects" 2>/dev/null || true
                    if [ ! -e "${HOME}/projects/${_slp_g}" ] && [ ! -L "${HOME}/projects/${_slp_g}" ]; then
                        ln -s "${_slp_base}/${_slp_g}" "${HOME}/projects/${_slp_g}" 2>/dev/null || true
                    fi
                fi
            done
        done
        unset _slp_g _slp_base
    fi

    # Friendly expiry notice when interactive login pod has < 6h remaining
    case "$-" in
        *i*)
            if [ -t 1 ] && [ "${LOGIN_SESSION_MODE:-login}" = "login" ] && [ -n "${LOGIN_JOB_ID:-}" ] && [ ! -f "${HOME:-/nonexistent}/.hushlogin" ]; then
                _slp_left="$(timeout 1 squeue -h -j "${LOGIN_JOB_ID}" -o "%L" 2>/dev/null | head -n 1 || true)"
                case "${_slp_left}" in
                    *-*|"") ;;
                    [0-5]:[0-9][0-9]:[0-9][0-9]|[0-9][0-9]:[0-9][0-9])
                        printf '\033[33mNotice:\033[0m login pod %s expires in %s — run "login-pod restart" when convenient to start a fresh pod.\n' "${LOGIN_JOB_ID}" "${_slp_left}"
                        ;;
                esac
                unset _slp_left
            fi
            ;;
    esac
fi

unset _slp_uid _slp_user
