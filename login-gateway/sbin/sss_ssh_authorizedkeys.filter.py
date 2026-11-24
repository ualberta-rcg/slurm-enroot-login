#!/usr/bin/env python3
"""
sss_ssh_authorizedkeys.filter.py

Validates OpenSSH authorized_keys lines for Digital Research Alliance of Canada
MFA Automation ("robot") SSH access.

Only emits keys that satisfy ALL three mandatory Alliance constraints:
  1. `restrict` (or all five explicit `no-pty`, `no-agent-forwarding`,
     `no-port-forwarding`, `no-x11-forwarding`, `no-user-rc` options), with
     zero re-enabling options (`pty`, `agent-forwarding`, `port-forwarding`,
     `x11-forwarding`, `user-rc`, `permitopen`, `permitlisten`, `tunnel`).
  2. `from="<pattern-list>"` containing ONLY public IP addresses or narrow
     subnets/wildcards:
       - IPv4: exact public IP, CIDR `/24`..`/32`, or wildcard `x.y.z.*` with
         all first three octets explicitly specified (`x.y.*.*` is rejected).
       - IPv6: exact public IP, CIDR `/64`..`/128`, or wildcard with at least
         the first four hextets explicitly specified.
       - RFC1918 private, loopback, link-local, CGNAT, ULA, and multicast
         ranges are rejected unless `--allow-private-from` is passed.
  3. `command="<forced_command>"` with a non-empty single-line command string.

Rewrite modes:
  - `--rewrite-dispatch` (dedicated `robot.<cluster>` gateway):
    rewrites `command="<cmd>"` to
    `command="/usr/local/libexec/login-gateway/dispatch --robot -- <cmd>"`
  - `--inject-robot-marker` (shared Port-22 multiplexing):
    rewrites `command="<cmd>"` to `command="__LOGIN_GATEWAY_ROBOT__ <cmd>"`
"""
import argparse
import base64
import binascii
import ipaddress
import re
import shlex
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

ROBOT_MARKER_PREFIX = "__LOGIN_GATEWAY_ROBOT__ "
LEGACY_ROBOT_MARKER_PREFIX = "__LOGINBOX_ROBOT__ "
DEFAULT_DISPATCH_BIN = "/usr/local/libexec/login-gateway/dispatch"

FORBIDDEN_IPV4_NETS = [
    ipaddress.ip_network("0.0.0.0/8"),
    ipaddress.ip_network("10.0.0.0/8"),
    ipaddress.ip_network("100.64.0.0/10"),
    ipaddress.ip_network("127.0.0.0/8"),
    ipaddress.ip_network("169.254.0.0/16"),
    ipaddress.ip_network("172.16.0.0/12"),
    ipaddress.ip_network("192.168.0.0/16"),
    ipaddress.ip_network("224.0.0.0/4"),
    ipaddress.ip_network("240.0.0.0/4"),
]

FORBIDDEN_IPV6_NETS = [
    ipaddress.ip_network("::/128"),
    ipaddress.ip_network("::1/128"),
    ipaddress.ip_network("fc00::/7"),
    ipaddress.ip_network("fe80::/10"),
    ipaddress.ip_network("ff00::/8"),
]

IPV4_WILDCARD_RE = re.compile(r"^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.([0-9*?]+)$")
HOSTNAME_PATTERN_RE = re.compile(r"^[A-Za-z0-9*?.-]+\.[A-Za-z]{2,}$")


def is_public_ipv4_net(net: ipaddress.IPv4Network) -> bool:
    for bad in FORBIDDEN_IPV4_NETS:
        if net.overlaps(bad):
            return False
    return True


def is_public_ipv6_net(net: ipaddress.IPv6Network) -> bool:
    for bad in FORBIDDEN_IPV6_NETS:
        if net.overlaps(bad):
            return False
    if net.network_address.ipv4_mapped is not None:
        mapped_net = ipaddress.ip_network(f"{net.network_address.ipv4_mapped}/32")
        return is_public_ipv4_net(mapped_net)
    return True


def validate_single_from_pattern(
    pat: str,
    allow_wildcard_from: bool = False,
    allow_private_from: bool = False,
    allow_hostname_from: bool = False,
) -> bool:
    if not pat:
        return False

    if pat in ("*", "0.0.0.0/0", "::/0"):
        return allow_wildcard_from

    # Disallow whitespace or negation-only entries
    if any(ch.isspace() for ch in pat) or pat.startswith("!"):
        return False

    # 1. Exact IPv4 or IPv6 address (no '/' and no '*'/'?')
    if "/" not in pat and "*" not in pat and "?" not in pat:
        try:
            addr = ipaddress.ip_address(pat)
        except ValueError:
            return bool(allow_hostname_from and HOSTNAME_PATTERN_RE.match(pat))
        if isinstance(addr, ipaddress.IPv4Address):
            return allow_private_from or is_public_ipv4_net(ipaddress.ip_network(f"{addr}/32"))
        return allow_private_from or is_public_ipv6_net(ipaddress.ip_network(f"{addr}/128"))

    # 2. CIDR notation (IPv4 >= /24, IPv6 >= /64 unless allow_wildcard_from)
    if "/" in pat and "*" not in pat and "?" not in pat:
        try:
            net = ipaddress.ip_network(pat, strict=False)
        except ValueError:
            return False
        if isinstance(net, ipaddress.IPv4Network):
            if not allow_wildcard_from and net.prefixlen < 24:
                return False
            return allow_private_from or is_public_ipv4_net(net)
        if not allow_wildcard_from and net.prefixlen < 64:
            return False
        return allow_private_from or is_public_ipv6_net(net)

    # 3. IPv4 wildcard pattern: must specify first 3 octets (e.g. 216.18.209.*)
    if ":" not in pat:
        m = IPV4_WILDCARD_RE.match(pat)
        if not m:
            if allow_wildcard_from and re.match(r"^[0-9.*?]+$", pat):
                return True
            return bool(allow_hostname_from and HOSTNAME_PATTERN_RE.match(pat))
        octets = [int(m.group(1)), int(m.group(2)), int(m.group(3))]
        if any(o < 0 or o > 255 for o in octets):
            return False
        net24 = ipaddress.ip_network(f"{octets[0]}.{octets[1]}.{octets[2]}.0/24")
        return allow_private_from or is_public_ipv4_net(net24)

    # 4. IPv6 wildcard pattern: must specify at least first 4 hextets without wildcards
    if "::" in pat:
        head = pat.split("::", 1)[0]
        groups = [g for g in head.split(":") if g]
    else:
        groups = pat.split(":")
    if len(groups) < 4 and not allow_wildcard_from:
        return False
    fixed_groups = groups[:4]
    if any(not re.match(r"^[0-9a-fA-F]{1,4}$", g) for g in fixed_groups):
        return bool(allow_wildcard_from)
    try:
        net64 = ipaddress.ip_network(":".join(fixed_groups) + "::/64", strict=False)
    except ValueError:
        return False
    return allow_private_from or is_public_ipv6_net(net64)


def split_options_and_key(line: str) -> Optional[Tuple[str, str, str, str]]:
    s = line.strip()
    if not s or s.startswith("#"):
        return None

    first_word = s.split(None, 1)[0]
    if first_word in VALID_KEY_TYPES:
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
    rewrite_dispatch: bool = False,
    dispatch_bin: str = DEFAULT_DISPATCH_BIN,
    allow_wildcard_from: bool = False,
    allow_private_from: bool = False,
    allow_hostname_from: bool = False,
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

    raw_patterns = [p.strip() for p in from_pat.split(",")]
    if not raw_patterns or any(not p for p in raw_patterns):
        return None
    for pat in raw_patterns:
        if not validate_single_from_pattern(
            pat,
            allow_wildcard_from=allow_wildcard_from,
            allow_private_from=allow_private_from,
            allow_hostname_from=allow_hostname_from,
        ):
            return None

    dispatch_prefix = f"{dispatch_bin} --robot -- "

    rebuilt_opts: List[str] = []
    for k, v in opts:
        if v is None:
            rebuilt_opts.append(k)
        elif k == "command":
            clean_cmd = v
            for pfx in (ROBOT_MARKER_PREFIX, LEGACY_ROBOT_MARKER_PREFIX, dispatch_prefix):
                if clean_cmd.startswith(pfx):
                    clean_cmd = clean_cmd[len(pfx):]
                    break
            if rewrite_dispatch:
                new_cmd = dispatch_prefix + shlex.quote(clean_cmd)
            elif inject_robot_marker:
                new_cmd = ROBOT_MARKER_PREFIX + clean_cmd
            else:
                new_cmd = clean_cmd
            rebuilt_opts.append(f'command="{escape_openssh_quoted(new_cmd)}"')
        else:
            rebuilt_opts.append(f'{k}="{escape_openssh_quoted(v)}"')

    rebuilt_line = f"{','.join(rebuilt_opts)} {key_type} {key_b64}"
    if comment:
        rebuilt_line = f"{rebuilt_line} {comment}"
    return rebuilt_line


def filter_stream(
    lines,
    inject_robot_marker: bool = False,
    rewrite_dispatch: bool = False,
    dispatch_bin: str = DEFAULT_DISPATCH_BIN,
    allow_wildcard_from: bool = False,
    allow_private_from: bool = False,
    allow_hostname_from: bool = False,
) -> List[str]:
    out: List[str] = []
    for raw in lines:
        formatted = validate_and_format_robot_key(
            raw,
            inject_robot_marker=inject_robot_marker,
            rewrite_dispatch=rewrite_dispatch,
            dispatch_bin=dispatch_bin,
            allow_wildcard_from=allow_wildcard_from,
            allow_private_from=allow_private_from,
            allow_hostname_from=allow_hostname_from,
        )
        if formatted is not None:
            out.append(formatted)
    return out


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Filter OpenSSH authorized_keys for Alliance MFA Automation (robot) access."
    )
    parser.add_argument(
        "--rewrite-dispatch",
        action="store_true",
        help="Rewrite validated command=\"...\" to invoke login-gateway dispatch --robot.",
    )
    parser.add_argument(
        "--dispatch-bin",
        default=DEFAULT_DISPATCH_BIN,
        help="Path to login-gateway dispatch binary used with --rewrite-dispatch.",
    )
    parser.add_argument(
        "--inject-robot-marker",
        action="store_true",
        help="Prefix validated command=\"...\" with __LOGIN_GATEWAY_ROBOT__ for shared Port-22 routing.",
    )
    parser.add_argument(
        "--allow-wildcard-from",
        action="store_true",
        help="Allow broad from= wildcards/prefixes wider than /24 (IPv4) or /64 (IPv6).",
    )
    parser.add_argument(
        "--allow-private-from",
        action="store_true",
        help="Allow RFC1918 private, loopback, or link-local addresses in from=.",
    )
    parser.add_argument(
        "--allow-hostname-from",
        action="store_true",
        help="Allow DNS hostname patterns in from= (disabled per Alliance policy by default).",
    )
    args = parser.parse_args()

    for valid in filter_stream(
        sys.stdin,
        inject_robot_marker=args.inject_robot_marker,
        rewrite_dispatch=args.rewrite_dispatch,
        dispatch_bin=args.dispatch_bin,
        allow_wildcard_from=args.allow_wildcard_from,
        allow_private_from=args.allow_private_from,
        allow_hostname_from=args.allow_hostname_from,
    ):
        print(valid)
    return 0


if __name__ == "__main__":
    sys.exit(main())
