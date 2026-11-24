#!/usr/bin/env python3
"""
Unit & integration tests for:
  - login-gateway/libexec/dispatch (direct transfer fast-path vs sudo route delegation, robot -- <cmd> & --orig-cmd)
  - login-gateway/libexec/route (SUDO_USER enforcement, spoof rejection, hooks/identity requirement)
  - deploy/warewulf/render-overlays.sh & deploy/standalone/install.sh dry-run checks
"""
import base64
import os
import subprocess
import tempfile
import unittest

REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
DISPATCH = os.path.join(REPO_ROOT, "login-gateway", "libexec", "dispatch")
ROUTE = os.path.join(REPO_ROOT, "login-gateway", "libexec", "route")
RENDER_WW = os.path.join(REPO_ROOT, "deploy", "warewulf", "render-overlays.sh")
INSTALL_SA = os.path.join(REPO_ROOT, "deploy", "standalone", "install.sh")


class TestDispatcherAndRoute(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(dir=os.path.dirname(__file__), prefix=".tmp_test_")
        self.bindir = os.path.join(self.tmp.name, "bin")
        os.makedirs(self.bindir, exist_ok=True)
        self.conf = os.path.join(self.tmp.name, "login-gateway.conf")

        self.sudo_log = os.path.join(self.tmp.name, "sudo.log")
        self.mock_sudo = os.path.join(self.bindir, "sudo")
        with open(self.mock_sudo, "w", encoding="utf-8") as fh:
            fh.write(
                "#!/usr/bin/env bash\n"
                f'printf "%s\\n" "$@" > "{self.sudo_log}"\n'
                "exit 0\n"
            )
        os.chmod(self.mock_sudo, 0o755)

        mock_srun = os.path.join(self.bindir, "systemd-run")
        with open(mock_srun, "w", encoding="utf-8") as fh:
            fh.write("#!/usr/bin/env bash\nexit 1\n")
        os.chmod(mock_srun, 0o755)

    def tearDown(self):
        self.tmp.cleanup()

    def _write_conf(self, extra: str = ""):
        with open(self.conf, "w", encoding="utf-8") as fh:
            fh.write(
                f'GATEWAY_DIR="{self.tmp.name}"\n'
                'TRANSFER_FASTPATH="1"\n'
                + extra
            )

    def _base_env(self):
        env = os.environ.copy()
        env["PATH"] = f"{self.bindir}:{env.get('PATH', '')}"
        env["LOGIN_GATEWAY_CONF"] = self.conf
        env["LOGIN_GATEWAY_SUDO_BIN"] = self.mock_sudo
        env["LOGIN_GATEWAY_ROUTE_BIN"] = ROUTE
        env.pop("XDG_RUNTIME_DIR", None)
        return env

    def test_dispatch_routes_interactive_shell_via_sudo_route(self):
        self._write_conf()
        env = self._base_env()
        env.pop("SSH_ORIGINAL_COMMAND", None)

        res = subprocess.run([DISPATCH], env=env, capture_output=True, text=True)
        self.assertEqual(res.returncode, 0, res.stderr)
        with open(self.sudo_log, "r", encoding="utf-8") as fh:
            args = fh.read().splitlines()
        self.assertIn(ROUTE, args)

    def test_dispatch_executes_transfer_fastpath_without_sudo(self):
        self._write_conf()
        # Use /bin/echo mock via sftp-server or rsync? Notice classify-transfer resolves
        # /usr/bin/scp if present on host, so let's pass an rrsync wrapper resolved from PATH
        # OR test shim delegation vs direct execution cleanly with mock rrsync? Wait:
        # classify-transfer normalizes scp -> /usr/bin/scp; let's check shim delegation AND
        # test direct execution with `scp -t` into a temp file (reading /dev/null -> EOF 0/1 without sudo!).
        target_dir = os.path.join(self.tmp.name, "xfer")
        os.makedirs(target_dir, exist_ok=True)

        env = self._base_env()
        env["USER"] = "alice"
        env["SSH_ORIGINAL_COMMAND"] = f"scp -t {target_dir}"

        res = subprocess.run(
            [DISPATCH],
            env=env,
            stdin=subprocess.DEVNULL,
            capture_output=True,
            text=True,
        )
        # scp -t with EOF on stdin exits immediately without ever invoking sudo!
        self.assertFalse(os.path.exists(self.sudo_log), "Transfer fast-path must NOT invoke sudo route")

    def test_dispatch_shim_user_delegates_transfer_to_route_for_uid_switch(self):
        self._write_conf('SHIM_USERS="cilogon"\n')
        env = self._base_env()
        env["USER"] = "cilogon"
        env["SSH_ORIGINAL_COMMAND"] = "scp -t /scratch/user/data.tar"

        res = subprocess.run([DISPATCH], env=env, capture_output=True, text=True)
        self.assertEqual(res.returncode, 0, res.stderr)
        self.assertTrue(os.path.exists(self.sudo_log), "Shim user must delegate to route so hooks/identity switches UID")

    def test_dispatch_robot_non_transfer_routes_to_robot_pod(self):
        self._write_conf()
        orig_cmd = "/cvmfs/soft.computecanada.ca/custom/bin/computecanada/allowed_commands/allowed_commands.sh"
        b64 = base64.b64encode(orig_cmd.encode()).decode()

        env = self._base_env()
        env["USER"] = "alice"
        env["SSH_ORIGINAL_COMMAND"] = "sbatch /scratch/alice/job.sh"

        res = subprocess.run(
            [DISPATCH, "--robot", "--orig-cmd", b64],
            env=env,
            capture_output=True,
            text=True,
        )
        self.assertEqual(res.returncode, 0, res.stderr)
        with open(self.sudo_log, "r", encoding="utf-8") as fh:
            args = fh.read().splitlines()
        self.assertIn("--robot", args)
        self.assertIn(orig_cmd, args)

    def test_route_rejects_unprivileged_user_spoofing(self):
        self._write_conf()
        env = self._base_env()
        env["SUDO_USER"] = "mallory"

        res = subprocess.run(
            [ROUTE, "--user", "victim"],
            env=env,
            capture_output=True,
            text=True,
        )
        self.assertNotEqual(res.returncode, 0)
        self.assertIn("only root may specify --user", res.stderr)

        res2 = subprocess.run(
            [ROUTE, "victim"],
            env=env,
            capture_output=True,
            text=True,
        )
        self.assertNotEqual(res2.returncode, 0)
        self.assertIn("only root may specify target user", res2.stderr)

    def test_route_shim_user_requires_identity_hook(self):
        self._write_conf('SHIM_USERS="cilogon"\n')
        env = self._base_env()
        env["SUDO_USER"] = "cilogon"

        res = subprocess.run(
            [ROUTE],
            env=env,
            capture_output=True,
            text=True,
        )
        self.assertNotEqual(res.returncode, 0)
        self.assertIn("no valid root-owned identity hook", res.stderr)

    def test_deploy_render_and_install_dry_run(self):
        out_dir = os.path.join(self.tmp.name, "ww")
        r1 = subprocess.run(
            [RENDER_WW, "--output-dir", out_dir, "--dry-run"],
            capture_output=True,
            text=True,
        )
        self.assertEqual(r1.returncode, 0, r1.stderr)
        r2 = subprocess.run(
            [INSTALL_SA, "--role", "login", "--with-status", "--with-guardrails", "--dry-run"],
            capture_output=True,
            text=True,
        )
        self.assertEqual(r2.returncode, 0, r2.stderr)


if __name__ == "__main__":
    unittest.main()
