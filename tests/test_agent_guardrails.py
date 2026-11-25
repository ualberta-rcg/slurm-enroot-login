"""Unit tests for agent-guardrails CLI and single-source guardrails sync."""

from __future__ import annotations

import os
import pathlib
import subprocess
import tempfile
import unittest

REPO_ROOT = pathlib.Path(__file__).resolve().parent.parent
CLI = str(REPO_ROOT / "agent-guardrails/bin/agent-guardrails")


class AgentGuardrailsCliTests(unittest.TestCase):
    def test_robot_mode_is_noop(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            res = subprocess.run(
                [CLI, "link"],
                env={**os.environ, "HOME": td, "LOGIN_SESSION_MODE": "robot"},
                text=True,
                capture_output=True,
                check=False,
            )
            self.assertEqual(res.returncode, 0)
            self.assertEqual(list(pathlib.Path(td).iterdir()), [])

    def test_link_never_overwrites_existing_user_files(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            home = pathlib.Path(td)
            codex_dir = home / ".codex"
            codex_dir.mkdir(parents=True)
            custom_agents = codex_dir / "AGENTS.md"
            custom_agents.write_text("# my custom notes\n")
            res = subprocess.run(
                [CLI, "link"],
                env={**os.environ, "HOME": td, "LOGIN_SESSION_MODE": "login", "LOGIN_GUARDRAILS_ENABLED": "1"},
                text=True,
                capture_output=True,
                check=False,
            )
            self.assertEqual(res.returncode, 0)
            self.assertFalse(custom_agents.is_symlink())
            self.assertEqual(custom_agents.read_text(), "# my custom notes\n")

    def test_status_reports_mode_and_policy(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            res = subprocess.run(
                [CLI, "status"],
                env={**os.environ, "HOME": td, "LOGIN_SESSION_MODE": "admin", "LOGIN_GUARDRAILS_ENABLED": "0"},
                text=True,
                capture_output=True,
                check=False,
            )
            self.assertEqual(res.returncode, 0)
            self.assertIn("informational (admin unrestricted)", res.stdout)

    def test_single_source_guardrails_synced(self) -> None:
        src = (REPO_ROOT / "agent-guardrails/src/guardrails.md").read_bytes()
        claude_md = (REPO_ROOT / "agent-guardrails/etc/claude-code/CLAUDE.md").read_bytes()
        agents_md = (REPO_ROOT / "agent-guardrails/etc/agents/AGENTS.md").read_bytes()
        self.assertEqual(src, claude_md)
        self.assertEqual(src, agents_md)


if __name__ == "__main__":
    unittest.main()
