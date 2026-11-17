#!/usr/bin/env python3
import importlib.util
import os
import unittest

FILTER_PATH = os.path.abspath(
    os.path.join(os.path.dirname(__file__), "..", "bin", "sss_ssh_authorizedkeys.filter.py")
)
spec = importlib.util.spec_from_file_location("robot_filter", FILTER_PATH)
robot_filter = importlib.util.module_from_spec(spec)
spec.loader.exec_module(robot_filter)

SAMPLE_ED25519 = "AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl"


class TestRobotKeyFilter(unittest.TestCase):
    def test_accepts_valid_restrict_from_command(self):
        line = f'restrict,from="198.51.100.10,198.51.100.0/24",command="/usr/bin/sbatch /home/user/run.sh" ssh-ed25519 {SAMPLE_ED25519} robot@workflow'
        res = robot_filter.validate_and_format_robot_key(line, inject_robot_marker=False)
        self.assertIsNotNone(res)
        self.assertIn('command="/usr/bin/sbatch /home/user/run.sh"', res)

    def test_injects_port22_robot_marker(self):
        line = f'restrict,from="198.51.100.10",command="/usr/bin/rrsync /scratch/user/data" ssh-ed25519 {SAMPLE_ED25519}'
        res = robot_filter.validate_and_format_robot_key(line, inject_robot_marker=True)
        self.assertIsNotNone(res)
        self.assertIn('command="__LOGINBOX_ROBOT__ /usr/bin/rrsync /scratch/user/data"', res)

    def test_accepts_explicit_five_no_flags(self):
        opts = "no-pty,no-agent-forwarding,no-port-forwarding,no-x11-forwarding,no-user-rc"
        line = f'{opts},from="203.0.113.5",command="/bin/true" ssh-ed25519 {SAMPLE_ED25519}'
        res = robot_filter.validate_and_format_robot_key(line, inject_robot_marker=True)
        self.assertIsNotNone(res)

    def test_rejects_unrestricted_key(self):
        line = f"ssh-ed25519 {SAMPLE_ED25519} laptop@example"
        self.assertIsNone(robot_filter.validate_and_format_robot_key(line))

    def test_rejects_missing_from_or_command(self):
        no_from = f'restrict,command="/bin/date" ssh-ed25519 {SAMPLE_ED25519}'
        no_cmd = f'restrict,from="198.51.100.10" ssh-ed25519 {SAMPLE_ED25519}'
        no_restrict = f'from="198.51.100.10",command="/bin/date" ssh-ed25519 {SAMPLE_ED25519}'
        self.assertIsNone(robot_filter.validate_and_format_robot_key(no_from))
        self.assertIsNone(robot_filter.validate_and_format_robot_key(no_cmd))
        self.assertIsNone(robot_filter.validate_and_format_robot_key(no_restrict))

    def test_rejects_pty_reenable_after_restrict(self):
        line = f'restrict,pty,from="198.51.100.10",command="/bin/date" ssh-ed25519 {SAMPLE_ED25519}'
        self.assertIsNone(robot_filter.validate_and_format_robot_key(line))

    def test_rejects_wildcard_from_by_default(self):
        star = f'restrict,from="*",command="/bin/date" ssh-ed25519 {SAMPLE_ED25519}'
        cidr0 = f'restrict,from="0.0.0.0/0",command="/bin/date" ssh-ed25519 {SAMPLE_ED25519}'
        self.assertIsNone(robot_filter.validate_and_format_robot_key(star))
        self.assertIsNone(robot_filter.validate_and_format_robot_key(cidr0))

    def test_preserves_escaped_quotes_in_command(self):
        line = rf'restrict,from="198.51.100.9",command="/usr/local/bin/run --tag \"nightly build\"" ssh-ed25519 {SAMPLE_ED25519}'
        res = robot_filter.validate_and_format_robot_key(line, inject_robot_marker=True)
        self.assertIsNotNone(res)
        self.assertIn(r'command="__LOGINBOX_ROBOT__ /usr/local/bin/run --tag \"nightly build\""', res)


if __name__ == "__main__":
    unittest.main()
