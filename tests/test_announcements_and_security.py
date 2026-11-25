"""Unit tests for announcements, robot shim refusal, stop positional mode, and import-image safety."""

from __future__ import annotations

import os
import pathlib
import stat
import subprocess
import tempfile
import unittest

REPO_ROOT = pathlib.Path(__file__).resolve().parent.parent
CLUSTER_STATUS = str(REPO_ROOT / "status/bin/cluster-status")
ANNOUNCE_CLI = str(REPO_ROOT / "status/sbin/cluster-status-announce")
ROUTE = str(REPO_ROOT / "login-gateway/libexec/route")
STOP = str(REPO_ROOT / "login-gateway/libexec/stop")
IMPORT_IMAGE = str(REPO_ROOT / "deploy/warewulf/import-image.sh")


class AnnouncementTests(unittest.TestCase):
    def test_priority_cli_over_env_over_conf(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            p = pathlib.Path(td)
            f_conf = p / "conf.txt"
            f_env = p / "env.txt"
            f_cli = p / "cli.txt"
            f_conf.write_text("from-conf\n")
            f_env.write_text("from-env\n")
            f_cli.write_text("from-cli\n")
            motd_conf = p / "motd.conf"
            motd_conf.write_text(f'ANNOUNCE="{f_conf}"\n')

            base_env = {**os.environ, "CLUSTER_STATUS_CONF": str(motd_conf)}
            base_env.pop("CLUSTER_STATUS_ANNOUNCE", None)

            r1 = subprocess.run([CLUSTER_STATUS, "--plain", "--only", "notice"], env=base_env, text=True, capture_output=True, check=True)
            self.assertIn("from-conf", r1.stdout)

            r2 = subprocess.run(
                [CLUSTER_STATUS, "--plain", "--only", "notice"],
                env={**base_env, "CLUSTER_STATUS_ANNOUNCE": str(f_env)},
                text=True,
                capture_output=True,
                check=True,
            )
            self.assertIn("from-env", r2.stdout)
            self.assertNotIn("from-conf", r2.stdout)

            r3 = subprocess.run(
                [CLUSTER_STATUS, "--plain", "--only", "notice", "--announce", str(f_cli)],
                env={**base_env, "CLUSTER_STATUS_ANNOUNCE": str(f_env)},
                text=True,
                capture_output=True,
                check=True,
            )
            self.assertIn("from-cli", r3.stdout)
            self.assertNotIn("from-env", r3.stdout)

    def test_announce_dir_sorting_expiry_and_ansi_stripping(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            d = pathlib.Path(td) / "announce.d"
            d.mkdir()
            (d / "10-first.txt").write_text("expires: 2099-12-31 23:59\nFirst \x1b[31mred\x1b[0m\x07 notice\n")
            (d / "20-expired.txt").write_text("expires: 2000-01-01 00:00\nShould not appear\n")
            (d / "30-second.txt").write_text("Second notice\n")
            nologin = pathlib.Path(td) / "nologin"
            nologin.write_text("Drain window 18:00 UTC\n")

            res = subprocess.run(
                [CLUSTER_STATUS, "--plain", "--only", "notice", "--announce", str(d)],
                env={**os.environ, "CLUSTER_STATUS_NOLOGIN_FILE": str(nologin)},
                text=True,
                capture_output=True,
                check=True,
            )
            self.assertIn("[MAINTENANCE NOLOGIN] Drain window 18:00 UTC", res.stdout)
            self.assertIn("First red notice", res.stdout)
            self.assertNotIn("\x1b[31m", res.stdout)
            self.assertNotIn("\x07", res.stdout)
            self.assertNotIn("Should not appear", res.stdout)
            self.assertLess(res.stdout.index("First red notice"), res.stdout.index("Second notice"))

    def test_announce_helper_set_append_show_clear(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            d = pathlib.Path(td) / "announce.d"
            env = {
                **os.environ,
                "CLUSTER_STATUS_ANNOUNCE": str(d),
                "CLUSTER_STATUS_ANNOUNCE_TEST_NONROOT": "1",
            }
            r_set = subprocess.run(
                [ANNOUNCE_CLI, "set", "--expires", "2099-01-01 12:00", "Storage maintenance Tuesday"],
                env=env,
                text=True,
                capture_output=True,
                check=True,
            )
            self.assertIn("Wrote announcement", r_set.stdout)
            r_show = subprocess.run([ANNOUNCE_CLI, "show"], env=env, text=True, capture_output=True, check=True)
            self.assertIn("Storage maintenance Tuesday", r_show.stdout)

            subprocess.run([ANNOUNCE_CLI, "clear"], env=env, text=True, capture_output=True, check=True)
            r_empty = subprocess.run([ANNOUNCE_CLI, "show"], env=env, text=True, capture_output=True, check=True)
            self.assertNotIn("Storage maintenance Tuesday", r_empty.stdout)


class SecurityAndRobotShimTests(unittest.TestCase):
    def test_route_refuses_robot_for_shim_identity(self) -> None:
        with tempfile.TemporaryDirectory(dir=str(REPO_ROOT / "tests"), prefix=".tmp_sec_") as td:
            p = pathlib.Path(td)
            bindir = p / "bin"
            bindir.mkdir()
            # Mock getent and id so route resolves a valid cluster account (>= 10000) without host LDAP
            getent = bindir / "getent"
            getent.write_text('#!/usr/bin/env bash\necho "alice:x:50001:50001::/tmp:/bin/bash"\n')
            getent.chmod(0o755)
            conf = p / "login-gateway.conf"
            conf.write_text(
                f'GATEWAY_DIR="{p}"\n'
                'SHIM_USERS="cilogon"\n'
                'ROBOT_ENABLED="1"\n'
            )
            env = {
                **os.environ,
                "PATH": f"{bindir}:{os.environ.get('PATH', '')}",
                "LOGIN_GATEWAY_CONF": str(conf),
                "SUDO_USER": "cilogon",
            }
            res = subprocess.run([ROUTE, "--robot", "alice"], env=env, text=True, capture_output=True, check=False)
            self.assertNotEqual(res.returncode, 0)
            self.assertIn("not supported for OIDC/CILogon shim accounts", res.stderr)

    def test_import_image_refuses_to_overwrite_existing_sqsh(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            existing = pathlib.Path(td) / "slurm-login-pods-26.05.6-1.sqsh"
            existing.write_bytes(b"hsqsexisting")
            res = subprocess.run(
                [IMPORT_IMAGE, "docker://example/image:tag", str(existing)],
                text=True,
                capture_output=True,
                check=False,
            )
            self.assertNotEqual(res.returncode, 0)
            self.assertIn("refusing to overwrite", res.stderr)
            self.assertEqual(existing.read_bytes(), b"hsqsexisting")

    def test_stop_positional_mode_validation(self) -> None:
        with tempfile.TemporaryDirectory(dir=str(REPO_ROOT / "tests"), prefix=".tmp_sec_") as td:
            bindir = pathlib.Path(td) / "bin"
            bindir.mkdir()
            squeue_log = pathlib.Path(td) / "squeue.log"
            mock_sq = bindir / "squeue"
            mock_sq.write_text(f'#!/usr/bin/env bash\nprintf "%s\\n" "$*" >> "{squeue_log}"\nexit 0\n')
            mock_sq.chmod(stat.S_IRWXU)
            env = {**os.environ, "PATH": f"{bindir}:{os.environ.get('PATH', '')}"}

            res = subprocess.run([STOP, "alice", "login"], env=env, text=True, capture_output=True, check=False)
            self.assertEqual(res.returncode, 0, res.stderr)
            logged = squeue_log.read_text()
            self.assertIn("-n login-alice", logged)
            self.assertNotIn("admin-alice", logged)

            bad = subprocess.run([STOP, "alice", "bogus"], env=env, text=True, capture_output=True, check=False)
            self.assertNotEqual(bad.returncode, 0)


if __name__ == "__main__":
    unittest.main()
