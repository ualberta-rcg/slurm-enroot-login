#!/usr/bin/env python3
"""
scan_secrets_pii.py

Enforces public-repository hygiene for `slurm-enroot-login`:
  - Zero private keys, TLS certificates, API tokens, or inline passwords
  - Zero Duo integration/secret keys or CILogon client secrets
  - Zero hashed OIDC user identifiers (`clg_<hex>`) or real staff usernames
  - Zero internal/public site IP addresses or site domain names
"""
import os
import re
import sys

REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
SELF_REL = os.path.relpath(os.path.abspath(__file__), REPO_ROOT)

# Patterns are constructed via concatenation where needed so this file never
# triggers naive scanners either.
PATTERNS = [
    ("private_key", re.compile(r"BEGIN " + r"(RSA|EC|OPENSSH|DSA|PGP|PRIVATE) KEY")),
    ("certificate", re.compile("-----BEGIN" + " CERTIFICATE-----")),
    ("inline_secret", re.compile(r"^\s*(password|passwd|secret|token|api_key|apikey|oidc_client_secret)\s*[:=]\s*['\"]?[A-Za-z0-9+/=_-]{8,}", re.IGNORECASE)),
    ("aws_key", re.compile(r"AKIA[0-9A-Z]{16}")),
    ("slack_token", re.compile(r"xox[baprs]-[0-9A-Za-z-]{10,}")),
    ("github_token", re.compile(r"gh[pousr]_[A-Za-z0-9]{36,}")),
    ("duo_ikey", re.compile(r"\bDI[A-Z0-9]{18}\b")),
    ("cilogon_client", re.compile(r"cilogon:/client_id/[0-9a-f]{16,}")),
    ("cilogon_user_hash", re.compile(r"\b" + "clg_" + r"[0-9a-f]{6,}\b")),
    ("site_ip_public", re.compile(r"\b129\.128\.\d{1,3}\.\d{1,3}\b")),
    ("site_ip_internal", re.compile(r"\b10\.254\.\d{1,3}\.\d{1,3}\b")),
    ("site_ip_campus", re.compile(r"\b172\.26\.\d{1,3}\.\d{1,3}\b")),
    ("site_domain", re.compile(r"paice" + r"-ua\.com", re.IGNORECASE)),
    ("site_ldap_dc", re.compile(r"dc=eur" + r"eka,dc=drs", re.IGNORECASE)),
]


def scan_repo(root: str) -> int:
    hits = []
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if d not in (".git", "__pycache__", "debs")]
        for fname in filenames:
            full_path = os.path.join(dirpath, fname)
            rel_path = os.path.relpath(full_path, root)
            if rel_path == SELF_REL:
                continue
            try:
                with open(full_path, "r", encoding="utf-8", errors="replace") as fh:
                    for lineno, line in enumerate(fh, 1):
                        for label, rx in PATTERNS:
                            if rx.search(line):
                                hits.append(f"{rel_path}:{lineno} [{label}]: {line.strip()[:120]}")
                                break
            except OSError:
                continue

    if hits:
        for h in hits[:20]:
            print(f"MATCH: {h}", file=sys.stderr)
        print(
            f"ERROR: Found {len(hits)} secret/PII/site-specific pattern(s). "
            "Move site values to runtime configuration (see SECRETS.md).",
            file=sys.stderr,
        )
        return 1

    print("OK: 0 secret, credential, or PII patterns found.")
    return 0


if __name__ == "__main__":
    sys.exit(scan_repo(REPO_ROOT))
