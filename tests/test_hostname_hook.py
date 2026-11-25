"""Unit tests for login-gateway/etc/enroot/hooks.d/50-login-pod-hostname.sh."""

from __future__ import annotations

import os
import pathlib
import subprocess
import tempfile
import unittest

REPO_ROOT = pathlib.Path(__file__).resolve().parent.parent
HOOK = str(REPO_ROOT / "login-gateway/etc/enroot/hooks.d/50-login-pod-hostname.sh")


class HostnameHookTests(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.work = pathlib.Path(self._tmp.name)
        (self.work / "rootfs/etc").mkdir(parents=True)
        (self.work / "runtime").mkdir()
        (self.work / "state/pod-hostname").mkdir(parents=True)
        (self.work / "rootfs/etc/slurm-login-pods-release").write_text("slurm-login-pods test\n")
        (self.work / "uid_map_userns").write_text("50001 50001 1\n")
        (self.work / "uid_map_host").write_text("0 0 4294967295\n")
        os.symlink("uts:[4026532999]", self.work / "uts_pod")
        os.symlink("uts:[4026531838]", self.work / "uts_init")
        (self.work / "mounts").write_text("")
        self.record_file = self.work / "recorded_hostname"

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def _run_hook(self, **overrides: str) -> subprocess.CompletedProcess[str]:
        env = {
            **os.environ,
            "LOGIN_POD_HOOK_TEST_MODE": "1",
            "LOGIN_POD_HOOK_UID_MAP": str(self.work / "uid_map_userns"),
            "LOGIN_POD_HOOK_SELF_UTS": str(self.work / "uts_pod"),
            "LOGIN_POD_HOOK_INIT_UTS": str(self.work / "uts_init"),
            "LOGIN_POD_HOOK_RECORD_FILE": str(self.record_file),
            "LOGIN_POD_HOOK_STATE_DIR": str(self.work / "state"),
            "ENROOT_ROOTFS": str(self.work / "rootfs"),
            "ENROOT_RUNTIME_PATH": str(self.work / "runtime"),
            "ENROOT_MOUNTS": str(self.work / "mounts"),
            "LOGIN_GATEWAY_POD_HOSTNAME": "cluster-login-alice",
            **overrides,
        }
        return subprocess.run([HOOK], env=env, text=True, capture_output=True, check=False)

    def test_refuses_initial_host_userns(self) -> None:
        res = self._run_hook(LOGIN_POD_HOOK_UID_MAP=str(self.work / "uid_map_host"))
        self.assertEqual(res.returncode, 0)
        self.assertFalse(self.record_file.exists())

    def test_refuses_matching_pid1_uts_namespace(self) -> None:
        res = self._run_hook(LOGIN_POD_HOOK_SELF_UTS=str(self.work / "uts_init"))
        self.assertEqual(res.returncode, 0)
        self.assertFalse(self.record_file.exists())

    def test_skips_non_login_pod_container(self) -> None:
        (self.work / "rootfs/etc/slurm-login-pods-release").unlink()
        res = self._run_hook()
        self.assertEqual(res.returncode, 0)
        self.assertFalse(self.record_file.exists())

    def test_sets_hostname_and_etc_mounts_in_unshared_pod(self) -> None:
        res = self._run_hook()
        self.assertEqual(res.returncode, 0)
        self.assertEqual(self.record_file.read_text().strip(), "cluster-login-alice")
        mounts = (self.work / "mounts").read_text()
        self.assertIn("/etc/hostname none", mounts)
        self.assertIn("/etc/hosts none", mounts)

    def test_reads_root_owned_state_fallback_when_env_scrubbed(self) -> None:
        state_file = self.work / "state/pod-hostname/50001"
        state_file.write_text("cluster-login-bob\n")
        # Untrusted owner UID must be ignored
        untrusted = self._run_hook(
            LOGIN_GATEWAY_POD_HOSTNAME="",
            LOGIN_POD_HOOK_EXPECTED_OWNER_UID="99999",
        )
        self.assertEqual(untrusted.returncode, 0)
        self.assertFalse(self.record_file.exists())

        # Expected owner UID succeeds
        res = self._run_hook(
            LOGIN_GATEWAY_POD_HOSTNAME="",
            LOGIN_POD_HOOK_EXPECTED_OWNER_UID=str(os.getuid()),
        )
        self.assertEqual(res.returncode, 0)
        self.assertEqual(self.record_file.read_text().strip(), "cluster-login-bob")

    def test_rejects_invalid_rfc1123_hostnames(self) -> None:
        for bad in ("-bad", "bad-", "bad_name", "bad;id", "a" * 64):
            res = self._run_hook(LOGIN_GATEWAY_POD_HOSTNAME=bad)
            self.assertEqual(res.returncode, 0)
            self.assertFalse(self.record_file.exists())


if __name__ == "__main__":
    unittest.main()
