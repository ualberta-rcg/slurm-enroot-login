#!/usr/bin/env python3
"""
scan_secrets_pii.py

Enforces public-repository hygiene for `slurm-login-pods`:
  - Zero private keys, TLS certificates, API tokens, or inline passwords
  - Zero Duo integration/secret keys or OIDC/CILogon client secrets
  - Zero hashed OIDC user identifiers (`clg_<hex>`)
  - Zero site-internal IP addresses, Eureka references, or internal domains
"""
import os
import re
import sys

REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
SELF_REL = os.path.relpath(os.path.abspath(__file__), REPO_ROOT)
BINARY_EXTS = {".png", ".jpg", ".jpeg", ".gif", ".webp", ".ico", ".pdf", ".sqsh", ".deb"}

PATTERNS = [
    ("private_key", re.compile(r"BEGIN " + r"(RSA|EC|OPENSSH|DSA|PGP|PRIVATE) KEY")),
    ("certificate", re.compile("-----BEGIN" + " CERTIFICATE-----")),
    (
        "inline_secret",
        re.compile(
            r"^\s*(password|passwd|secret|token|api_key|apikey|oidc_client_secret)\s*[:=]\s*['\"]?[A-Za-z0-9+/=_-]{8,}",
            re.IGNORECASE,
        ),
    ),
    ("aws_key", re.compile(r"AKIA[0-9A-Z]{16}")),
    ("openai_or_anthropic_key", re.compile(r"\bsk-(proj-|ant-)?[A-Za-z0-9_-]{20,}\b")),
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
    ("site_cluster_name", re.compile(r"\beur" + r"eka\b", re.IGNORECASE)),
]


def scan_repo(root: str) -> int:
    hits = []
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if d not in (".git", "__pycache__", "debs")]
        for fname in filenames:
            _, ext = os.path.splitext(fname)
            if ext.lower() in BINARY_EXTS:
                continue
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
        for h in hits[:30]:
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
