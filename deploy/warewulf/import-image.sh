#!/usr/bin/env bash
# =============================================================================
# import-image.sh — safely import a versioned Enroot SquashFS login-pod image
# =============================================================================
# Running login/robot/admin pods keep their SquashFS backing file open via
# squashfuse / kernel loop mounts. Overwriting an in-use .sqsh file on shared
# storage causes immediate EIO / ESTALE errors inside running user sessions.
#
# This helper:
#   1. Refuses to overwrite an existing destination .sqsh file.
#   2. Imports via `enroot import` into a temporary file in the destination
#      directory (or staging dir), verifies SquashFS magic, sets mode 0644,
#      and atomically renames into place.
# =============================================================================
set -euo pipefail

usage() {
    cat <<'EOF'
Usage:
  import-image.sh <docker://org/repo:tag> <dest-versioned-path.sqsh>

Example:
  import-image.sh docker://vulcanrcg/slurm-login-pods:26.05.6-2 \
      /cache/slurm-login-pods-26.05.6-2.sqsh
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" || $# -ne 2 ]]; then
    usage >&2
    [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && exit 0 || exit 2
fi

SRC_URI="$1"
DEST_SQSH="$2"

if [[ "$DEST_SQSH" != *.sqsh ]]; then
    echo "ERROR: destination path must end in .sqsh (${DEST_SQSH})." >&2
    exit 2
fi

if [[ -e "$DEST_SQSH" || -L "$DEST_SQSH" ]]; then
    echo "ERROR: destination '${DEST_SQSH}' already exists — refusing to overwrite an image that running pods may have mounted." >&2
    echo "Import to a new versioned filename (e.g. *-26.05.6-2.sqsh) and update IMAGE_PATH / ADMIN_IMAGE_PATH." >&2
    exit 1
fi

if ! command -v enroot >/dev/null 2>&1; then
    echo "ERROR: 'enroot' CLI not found on PATH." >&2
    exit 1
fi

DEST_DIR=$(dirname "$DEST_SQSH")
mkdir -p "$DEST_DIR"
STAGE_SQSH="${DEST_DIR}/.$(basename "$DEST_SQSH").importing.$$"

cleanup() {
    rm -f "$STAGE_SQSH"
}
trap cleanup EXIT

echo "Importing ${SRC_URI} -> ${STAGE_SQSH} ..."
enroot import -o "$STAGE_SQSH" "$SRC_URI"

MAGIC=$(head -c 4 "$STAGE_SQSH" 2>/dev/null || true)
if [[ "$MAGIC" != "hsqs" ]]; then
    echo "ERROR: imported file '${STAGE_SQSH}' does not have valid SquashFS magic ('hsqs')." >&2
    exit 1
fi

chmod 0644 "$STAGE_SQSH"
mv -n "$STAGE_SQSH" "$DEST_SQSH"
if [[ ! -f "$DEST_SQSH" ]]; then
    echo "ERROR: atomic move to '${DEST_SQSH}' failed (destination appeared concurrently)." >&2
    exit 1
fi
trap - EXIT
ls -lh "$DEST_SQSH"
