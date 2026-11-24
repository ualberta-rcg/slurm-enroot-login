#!/usr/bin/env bats
# BATS test suite for login-gateway/libexec/classify-transfer

setup() {
    REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
    CLASSIFY="${REPO_ROOT}/login-gateway/libexec/classify-transfer"
}

run_classify() {
    local cmd="$1"
    local orig="${2:-}"
    bash -c 'source "$1"; classify_transfer_cmd "$2" "$3" && printf "%s\n" "$NORMALIZED_XFER_CMD"' _ "$CLASSIFY" "$cmd" "$orig"
}

@test "scp -O sink and source modes pass" {
    run run_classify "scp -t /scratch/user/file.bin"
    [ "$status" -eq 0 ]
    run run_classify "scp -r -p -f -- /project/def-pi/results"
    [ "$status" -eq 0 ]
}

@test "sftp-server Ubuntu and RHEL paths plus internal-sftp pass" {
    run run_classify "/usr/lib/openssh/sftp-server"
    [ "$status" -eq 0 ]
    run run_classify "/usr/libexec/openssh/sftp-server -l INFO"
    [ "$status" -eq 0 ]
    run run_classify "internal-sftp"
    [ "$status" -eq 0 ]
}

@test "rsync --server passes while rsync --daemon is blocked" {
    run run_classify "rsync --server -vlogDtprze.iLsfxCIvu . /scratch/user/out"
    [ "$status" -eq 0 ]
    run run_classify "rsync --server --daemon ."
    [ "$status" -ne 0 ]
}

@test "rrsync read-only and directory confinement pass" {
    run run_classify "rrsync -ro /project/def-pi/share" "rsync --server -vlogDtpr . ."
    [ "$status" -eq 0 ]
}

@test "Alliance CVMFS transfer_commands.sh normalizes Ubuntu sftp-server to RHEL path" {
    run bash -c '
        source "$1"
        classify_transfer_cmd "/cvmfs/soft.computecanada.ca/custom/bin/computecanada/allowed_commands/transfer_commands.sh" "/usr/lib/openssh/sftp-server"
        printf "%s\n" "$NORMALIZED_XFER_ORIG_CMD"
    ' _ "$CLASSIFY"
    [ "$status" -eq 0 ]
    [ "$output" = "/usr/libexec/openssh/sftp-server" ]
}

@test "Alliance CVMFS allowed_commands.sh rejects non-transfer sbatch onto pod path" {
    run run_classify "/cvmfs/soft.computecanada.ca/custom/bin/computecanada/allowed_commands/allowed_commands.sh" "sbatch job.sh"
    [ "$status" -ne 0 ]
}

@test "shell metacharacter smuggling is rejected across all transfer modes" {
    run run_classify "scp -t /tmp/a; id"
    [ "$status" -ne 0 ]
    run run_classify 'rsync --server . $(whoami)'
    [ "$status" -ne 0 ]
    run run_classify "scp -t /tmp/a | cat /etc/passwd"
    [ "$status" -ne 0 ]
}
