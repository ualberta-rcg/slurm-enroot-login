#!/usr/bin/env python3
"""
sss_ssh_authorizedkeys.filter.py

Validates OpenSSH authorized_keys lines for Alliance-style Robot SSH access.
Only emits keys that satisfy ALL three mandatory restrictions:
  1. `restrict` (or all five explicit `no-pty`, `no-agent-forwarding`,
     `no-port-forwarding`, `no-x11-forwarding`, `no-user-rc` options), with
     no re-enabling options (`pty`, `agent-forwarding`, `port-forwarding`,
     `x11-forwarding`, `user-rc`, `permitopen`, `permitlisten`).
  2. `from="<pattern>"` with a non-empty host/CIDR allowlist (bare `*` or
     `0.0.0.0/0` wildcard-all is rejected unless `--allow-wildcard-from`).
  3. `command="<forced_command>"` with a non-empty command string.

When `--inject-robot-marker` is passed (used for single-Port-22 Robot SSH
detection), rewrites `command="<cmd>"` in memory on stdout to
`command="__LOGINBOX_ROBOT__ <cmd>"` while leaving `~/.ssh/authorized_keys`
on disk untouched in standard Alliance format.
"""
import argparse
import base64
import binascii
import sys
from typing import List, Optional, Tuple

VALID_KEY_TYPES = {
    "ssh-ed25519",
    "ssh-ed25519-cert-v01@openssh.com",
    "ssh-rsa",
    "rsa-sha2-256",
    "rsa-sha2-512",
    "ecdsa-sha2-nistp256",
    "ecdsa-sha2-nistp384",
    "ecdsa-sha2-nistp521",
    "sk-ssh-ed25519@openssh.com",
    "sk-ecdsa-sha2-nistp256@openssh.com",
}

EXPLICIT_NO_FLAGS = {
    "no-pty",
    "no-agent-forwarding",
    "no-port-forwarding",
    "no-x11-forwarding",
    "no-user-rc",
}

FORBIDDEN_REENABLE_OPTS = {
    "pty",
    "agent-forwarding",
    "port-forwarding",
    "x11-forwarding",
    "user-rc",
    "permitopen",
    "permitlisten",
    "tunnel",
}

ROBOT_MARKER_PREFIX = "__LOGINBOX_ROBOT__ "


def split_options_and_key(line: str) -> Optional[Tuple[str, str, str, str]]:
    """
    Splits an OpenSSH authorized_keys line into:
      (options_str, key_type, base64_key, comment)
    Returns None if malformed or if no options field is present.
    """
    s = line.strip()
    if not s or s.startswith("#"):
        return None

    first_word = s.split(None, 1)[0]
    if first_word in VALID_KEY_TYPES:
        # Unrestricted key (starts directly with key type, no options)
        return None

    in_quotes = False
    escape = False
    split_idx = -1
    for idx, ch in enumerate(s):
        if escape:
            escape = False
            continue
        if ch == "\\":
            escape = True
            continue
        if ch == '"':
            in_quotes = not in_quotes
            continue
        if not in_quotes and ch in (" ", "\t"):
            split_idx = idx
            break

    if in_quotes or escape or split_idx <= 0:
        return None

    options_str = s[:split_idx]
    rest = s[split_idx:].strip()
    parts = rest.split(None, 2)
    if len(parts) < 2:
        return None

    key_type, key_b64 = parts[0], parts[1]
    comment = parts[2] if len(parts) > 2 else ""

    if key_type not in VALID_KEY_TYPES:
        return None

    try:
        decoded = base64.b64decode(key_b64.encode("ascii"), validate=True)
        if len(decoded) < 16:
            return None
    except (binascii.Error, UnicodeEncodeError):
        return None

    return options_str, key_type, key_b64, comment


def parse_options(options_str: str) -> Optional[List[Tuple[str, Optional[str]]]]:
    """
    Parses comma-separated OpenSSH key options into [(name_lower, unescaped_val_or_None), ...].
    Returns None on syntax errors (unclosed quotes, trailing comma, unknown empty token).
    """
    tokens: List[str] = []
    cur: List[str] = []
    in_quotes = False
    escape = False

    for ch in options_str:
        if escape:
            cur.append("\\" + ch)
            escape = False
            continue
        if ch == "\\":
            escape = True
            continue
        if ch == '"':
            in_quotes = not in_quotes
            cur.append(ch)
            continue
        if not in_quotes and ch == ",":
            tokens.append("".join(cur))
            cur = []
            continue
        cur.append(ch)

    if in_quotes or escape:
        return None
    tokens.append("".join(cur))

    parsed: List[Tuple[str, Optional[str]]] = []
    for tok in tokens:
        tok = tok.strip()
        if not tok:
            return None
        if "=" not in tok:
            parsed.append((tok.lower(), None))
        else:
            k, v = tok.split("=", 1)
            k = k.strip().lower()
            if not k or len(v) < 2 or not (v.startswith('"') and v.endswith('"')):
                return None
            inner = v[1:-1]
            # Unescape \" and \\ inside OpenSSH quoted value
            unescaped: List[str] = []
            esc = False
            for c in inner:
                if esc:
                    unescaped.append(c)
                    esc = False
                elif c == "\\":
                    esc = True
                else:
                    unescaped.append(c)
            if esc:
                return None
            parsed.append((k, "".join(unescaped)))

    return parsed


def escape_openssh_quoted(val: str) -> str:
    return val.replace("\\", "\\\\").replace('"', '\\"')


def validate_and_format_robot_key(
    line: str,
    inject_robot_marker: bool = False,
    allow_wildcard_from: bool = False,
) -> Optional[str]:
    split_res = split_options_and_key(line)
    if split_res is None:
        return None
    options_str, key_type, key_b64, comment = split_res

    opts = parse_options(options_str)
    if opts is None:
        return None

    opt_names = {k for k, _ in opts}
    if opt_names & FORBIDDEN_REENABLE_OPTS:
        return None

    has_restrict = ("restrict" in opt_names) or EXPLICIT_NO_FLAGS.issubset(opt_names)
    if not has_restrict:
        return None

    from_vals = [v for k, v in opts if k == "from" and v is not None]
    cmd_vals = [v for k, v in opts if k == "command" and v is not None]

    if len(from_vals) != 1 or len(cmd_vals) != 1:
        return None

    from_pat = from_vals[0].strip()
    cmd_val = cmd_vals[0].strip()
    if not from_pat or not cmd_val:
        return None
    if "\n" in from_pat or "\r" in from_pat or "\n" in cmd_val or "\r" in cmd_val:
        return None

    if not allow_wildcard_from:
        patterns = [p.strip() for p in from_pat.split(",") if p.strip()]
        if not patterns:
            return None
        for pat in patterns:
            if pat in ("*", "0.0.0.0/0", "::/0"):
                return None

    rebuilt_opts: List[str] = []
    for k, v in opts:
        if v is None:
            rebuilt_opts.append(k)
        elif k == "command" and inject_robot_marker and not v.startswith(ROBOT_MARKER_PREFIX):
            rebuilt_opts.append(f'command="{escape_openssh_quoted(ROBOT_MARKER_PREFIX + v)}"')
        else:
            rebuilt_opts.append(f'{k}="{escape_openssh_quoted(v)}"')

    rebuilt_line = f"{','.join(rebuilt_opts)} {key_type} {key_b64}"
    if comment:
        rebuilt_line = f"{rebuilt_line} {comment}"
    return rebuilt_line


def filter_stream(
    lines,
    inject_robot_marker: bool = False,
    allow_wildcard_from: bool = False,
) -> List[str]:
    out: List[str] = []
    for raw in lines:
        formatted = validate_and_format_robot_key(
            raw,
            inject_robot_marker=inject_robot_marker,
            allow_wildcard_from=allow_wildcard_from,
        )
        if formatted is not None:
            out.append(formatted)
    return out


def main() -> int:
    parser = argparse.ArgumentParser(description="Filter OpenSSH authorized_keys for Robot access.")
    parser.add_argument(
        "--inject-robot-marker",
        action="store_true",
        help="Prefix validated command=\"...\" with __LOGINBOX_ROBOT__ for Port-22 routing.",
    )
    parser.add_argument(
        "--allow-wildcard-from",
        action="store_true",
        help="Allow from=\"*\" (disabled by default).",
    )
    args = parser.parse_args()

    for valid in filter_stream(
        sys.stdin,
        inject_robot_marker=args.inject_robot_marker,
        allow_wildcard_from=args.allow_wildcard_from,
    ):
        print(valid)
    return 0


if __name__ == "__main__":
    sys.exit(main())
