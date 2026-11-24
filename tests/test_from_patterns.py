#!/usr/bin/env python3
"""Unit tests for Alliance MFA Automation `from="..."` IPv4/IPv6 validation rules."""
import importlib.util
import os
import unittest

FILTER_PATH = os.path.abspath(
    os.path.join(os.path.dirname(__file__), "..", "login-gateway", "sbin", "sss_ssh_authorizedkeys.filter.py")
)
spec = importlib.util.spec_from_file_location("robot_filter", FILTER_PATH)
robot_filter = importlib.util.module_from_spec(spec)
spec.loader.exec_module(robot_filter)

SAMPLE_ED25519 = "AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl"


def make_key(from_val: str) -> str:
    return (
        f'restrict,from="{from_val}",'
        f'command="/cvmfs/soft.computecanada.ca/custom/bin/computecanada/allowed_commands/transfer_commands.sh" '
        f"ssh-ed25519 {SAMPLE_ED25519}"
    )


class TestAllianceFromPatterns(unittest.TestCase):
    def test_accepts_alliance_wiki_public_ipv4_and_ipv6_examples(self):
        accepted = (
            "216.18.209.*",
            "199.241.166.5",
            "199.241.166.0/24",
            "198.51.100.128/25",
            "203.0.113.1*",
            "2620:123:7002:4::5",
            "2620:123:7002:4::/64",
            "2001:db8:abcd:0012::/64",
            "2620:123:7002:4::*",
            "198.51.100.*,2620:123:7002:4::/64",
        )
        for pat in accepted:
            with self.subTest(pat=pat):
                self.assertIsNotNone(robot_filter.validate_and_format_robot_key(make_key(pat)))

    def test_rejects_broad_wildcards_and_wide_prefixes(self):
        rejected = (
            "*",
            "0.0.0.0/0",
            "::/0",
            "216.18.*.*",
            "216.18.*",
            "216.*.*.*",
            "199.241.0.0/16",
            "199.241.166.0/23",
            "2620:123:7002::/48",
            "2620:123:*",
        )
        for pat in rejected:
            with self.subTest(pat=pat):
                self.assertIsNone(robot_filter.validate_and_format_robot_key(make_key(pat)))

    def test_rejects_rfc1918_loopback_linklocal_cgnat_ula(self):
        private_or_reserved = (
            "10.0.20.*",
            "10.0.20.50",
            "10.0.20.0/24",
            "172.16.0.1",
            "172.20.5.*",
            "172.31.255.0/24",
            "192.168.1.*",
            "192.168.1.0/24",
            "127.0.0.1",
            "127.0.0.*",
            "169.254.10.*",
            "100.64.1.*",
            "::1",
            "fc00:1:2:3::1",
            "fd12:3456:789a:1::/64",
            "fe80:0:0:1::5",
            "198.51.100.*,10.0.0.*",  # mixed public + private must fail
        )
        for pat in private_or_reserved:
            with self.subTest(pat=pat):
                self.assertIsNone(robot_filter.validate_and_format_robot_key(make_key(pat)))

    def test_rejects_hostnames_and_negations_by_default(self):
        for pat in ("*.alliancecan.ca", " workstation.example.org", "!198.51.100.5"):
            with self.subTest(pat=pat):
                self.assertIsNone(robot_filter.validate_and_format_robot_key(make_key(pat)))

    def test_escape_hatches_work_when_explicitly_enabled(self):
        self.assertIsNotNone(
            robot_filter.validate_and_format_robot_key(make_key("10.0.20.*"), allow_private_from=True)
        )
        self.assertIsNotNone(
            robot_filter.validate_and_format_robot_key(make_key("198.51.0.0/16"), allow_wildcard_from=True)
        )
        self.assertIsNotNone(
            robot_filter.validate_and_format_robot_key(make_key("*.example.org"), allow_hostname_from=True)
        )


if __name__ == "__main__":
    unittest.main()
