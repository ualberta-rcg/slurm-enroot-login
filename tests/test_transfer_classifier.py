#!/usr/bin/env python3
import os
import subprocess
import unittest

ROUTE_SCRIPT = os.path.abspath(
    os.path.join(os.path.dirname(__file__), "..", "login-gateway", "libexec", "route")
)

CVMFS_XFER = "/cvmfs/soft.computecanada.ca/custom/bin/computecanada/allowed_commands/transfer_commands.sh"
CVMFS_ALL = "/cvmfs/soft.computecanada.ca/custom/bin/computecanada/allowed_commands/allowed_commands.sh"


def classify(cmd: str, orig_cmd: str = ""):
    proc = subprocess.run(
        ["/bin/bash", ROUTE_SCRIPT, "--classify-transfer", cmd, orig_cmd],
        capture_output=True,
        text=True,
        timeout=5,
    )
    return proc.returncode == 0, proc.stdout.strip()


class TestTransferClassifier(unittest.TestCase):
    def test_accepts_sftp_variants(self):
        for raw in (
            "/usr/lib/openssh/sftp-server",
            "/usr/libexec/openssh/sftp-server -l INFO",
            "sftp-server",
            "internal-sftp",
        ):
            ok, norm = classify(raw)
            self.assertTrue(ok, f"Expected sftp command to be accepted: {raw}")
            self.assertIn("sftp-server", norm)

    def test_accepts_scp_server_modes(self):
        for raw in (
            "scp -t /home/user/dest.bin",
            "scp -f /scratch/user/data.tar.gz",
            "/usr/bin/scp -r -p -d -t -- /projects/group/upload",
            "scp -rt /home/user/dir",
        ):
            ok, norm = classify(raw)
            self.assertTrue(ok, f"Expected scp server command to be accepted: {raw}")
            self.assertTrue(norm.startswith("/usr/bin/scp "))

    def test_accepts_rsync_server_and_rrsync(self):
        ok, norm = classify("rsync --server -vlogDtprze.iLsfxCIvu . /scratch/user/out")
        self.assertTrue(ok)
        self.assertTrue(norm.startswith("/usr/bin/rsync --server"))

        ok_rr, _ = classify(
            "/usr/bin/rrsync /scratch/user/drop",
            "rsync --server -vlogDtprze.iLsfxCIvu . .",
        )
        self.assertTrue(ok_rr)

    def test_accepts_alliance_cvmfs_wrappers_for_transfers(self):
        for wrapper in (CVMFS_XFER, CVMFS_ALL):
            for orig in (
                "scp -t /scratch/user/in.tar",
                "rsync --server -vlogDtprze.iLsfxCIvu . /scratch/user/dir",
                "/usr/libexec/openssh/sftp-server",
                "/usr/lib/openssh/sftp-server",
            ):
                ok, _ = classify(wrapper, orig)
                self.assertTrue(ok, f"Expected CVMFS wrapper {wrapper} + {orig} to fast-path")

    def test_routes_non_transfer_cvmfs_commands_to_robot_pod(self):
        for orig in ("sbatch run.sh", "squeue -u user", "git status", "python3 script.py", ""):
            ok, _ = classify(CVMFS_ALL, orig)
            self.assertFalse(ok, f"Non-transfer {orig!r} under allowed_commands.sh must go to robot pod")

    def test_rejects_non_transfer_and_client_commands(self):
        for raw in (
            "bash",
            "sbatch job.sh",
            "python3 train.py",
            "scp localfile otherhost:/tmp/",
            "rsync -avz /home/user /scratch/user",
            "/usr/bin/rrsync /scratch/user/drop",
        ):
            ok, _ = classify(raw)
            self.assertFalse(ok, f"Expected non-transfer command to be rejected: {raw}")

    def test_rejects_command_smuggling_metacharacters(self):
        smuggling = (
            "scp -t /tmp/a; python3 -c 'print(1)'",
            "scp -t /tmp/a && id",
            "scp -t /tmp/a | cat",
            "rsync --server -vlogDtpr . /tmp/a `id`",
            "rsync --server -vlogDtpr . $(id)",
            "rsync --server -vlogDtpr . ${HOME}/x",
            "sftp-server > /tmp/pwn",
            "scp -t /tmp/a\nid",
            (CVMFS_XFER, "scp -t /tmp/a; id"),
        )
        for item in smuggling:
            if isinstance(item, tuple):
                ok, _ = classify(item[0], item[1])
            else:
                ok, _ = classify(item)
            self.assertFalse(ok, f"Smuggling attempt must NOT run on gateway: {item!r}")


if __name__ == "__main__":
    unittest.main()
