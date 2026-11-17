#!/usr/bin/env python3
"""
/usr/local/bin/loginbox-webhook.py
Optional ContainerSSH Auth (/pubkey, /authz) and Config (/config) Webhook Server.

- Validates SSH public keys via SSSD/LDAP (`/usr/bin/sss_ssh_authorizedkeys <user>`)
  and `/etc/loginbox/client_authorized_keys`.
- Shares routing state with `switch-user.sh` and `login-spawn.sh` via:
  1. In-memory cache (`CACHE[username]`) + 100ms TCP probe (0 Slurm RPCs on warm connects)
  2. `/run/loginbox/routes/<user>` file cache
  3. Slurm job `Comment` (`<node>:<port>:<fingerprint>[,<pubkey_b64>]`) on job `login-<user>`
  4. Cold-path spawn via `/usr/local/bin/login-spawn.sh --user <user>`
"""
import json
import os
import socket
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

LISTEN_HOST = os.environ.get("WEBHOOK_HOST", "127.0.0.1")
LISTEN_PORT = int(os.environ.get("WEBHOOK_PORT", "18080"))
LOGINBOX_DIR = os.environ.get("LOGINBOX_DIR", "/etc/loginbox")
ROUTE_DIR = os.environ.get("ROUTE_DIR", "/run/loginbox/routes")
LOGIN_PARTITION = os.environ.get("LOGIN_PARTITION", "login")
PROXY_PRIVKEY_PATH = os.environ.get("PROXY_PRIVKEY_PATH", "/etc/loginbox/proxy_id_ed25519")
CLIENT_AUTHKEYS_PATH = os.environ.get("CLIENT_AUTHKEYS_PATH", "/etc/loginbox/client_authorized_keys")
SPAWN_SCRIPT = os.environ.get("SPAWN_SCRIPT", "/usr/local/bin/login-spawn.sh")

CACHE_LOCK = threading.Lock()
CACHE = {}  # username -> {"jobid": str, "node": str, "port": int, "fp": str, "updated_at": float}
SPAWN_LOCKS = {}
STATS = {
    "pubkey_requests": 0,
    "authz_requests": 0,
    "config_requests": 0,
    "cache_hits": 0,
    "cache_misses": 0,
    "squeue_calls": 0,
    "spawn_calls": 0,
}


def tcp_probe(host: str, port: int, timeout: float = 0.1) -> bool:
    try:
        with socket.create_connection((host, int(port)), timeout=timeout):
            return True
    except OSError:
        return False


def get_user_spawn_lock(username: str) -> threading.Lock:
    with CACHE_LOCK:
        if username not in SPAWN_LOCKS:
            SPAWN_LOCKS[username] = threading.Lock()
        return SPAWN_LOCKS[username]


def clean_fingerprint(fp_field: str) -> str:
    return fp_field.strip().split(",", 1)[0]


def parse_comment(comment: str):
    parts = comment.strip().split(":", 2)
    if len(parts) != 3:
        return None
    node, port_str, fp_raw = parts
    try:
        port = int(port_str)
    except ValueError:
        return None
    fp = clean_fingerprint(fp_raw)
    if not fp.startswith("SHA256:"):
        return None
    return node, port, fp_raw.strip()


def save_route_file(username: str, entry: dict):
    try:
        os.makedirs(ROUTE_DIR, exist_ok=True)
        path = os.path.join(ROUTE_DIR, username)
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(f"{entry['jobid']}|{entry['node']}|{entry['port']}|{entry['fp']}\n")
    except OSError:
        pass


def resolve_or_spawn_backend(username: str):
    with CACHE_LOCK:
        entry = CACHE.get(username)
    if entry is not None and tcp_probe(entry["node"], entry["port"], timeout=0.1):
        with CACHE_LOCK:
            STATS["cache_hits"] += 1
        return entry

    user_lock = get_user_spawn_lock(username)
    with user_lock:
        with CACHE_LOCK:
            entry = CACHE.get(username)
        if entry is not None and tcp_probe(entry["node"], entry["port"], timeout=0.1):
            with CACHE_LOCK:
                STATS["cache_hits"] += 1
            return entry

        route_path = os.path.join(ROUTE_DIR, username)
        if os.path.exists(route_path):
            try:
                raw = open(route_path, "r", encoding="utf-8").read().strip()
                parts = raw.split("|")
                if len(parts) == 4 and tcp_probe(parts[1], int(parts[2]), timeout=0.1):
                    entry = {
                        "jobid": parts[0],
                        "node": parts[1],
                        "port": int(parts[2]),
                        "fp": parts[3],
                        "updated_at": time.time(),
                    }
                    with CACHE_LOCK:
                        CACHE[username] = entry
                        STATS["cache_hits"] += 1
                    return entry
            except Exception:
                pass

        with CACHE_LOCK:
            STATS["cache_misses"] += 1
            STATS["squeue_calls"] += 1

        job_name = f"login-{username}"
        proc = subprocess.run(
            ["squeue", "-h", "-u", username, "-p", LOGIN_PARTITION, "-n", job_name, "-t", "R", "-o", "%i|%N|%k"],
            capture_output=True,
            text=True,
            timeout=10,
        )
        line = proc.stdout.strip().splitlines()[0] if proc.stdout.strip() else ""
        if line and "|" in line:
            jid, _jnode, comment = line.split("|", 2)
            parsed = parse_comment(comment)
            if parsed is not None:
                node, port, fp_raw = parsed
                if tcp_probe(node, port, timeout=0.2):
                    entry = {
                        "jobid": jid,
                        "node": node,
                        "port": port,
                        "fp": fp_raw,
                        "updated_at": time.time(),
                    }
                    with CACHE_LOCK:
                        CACHE[username] = entry
                    save_route_file(username, entry)
                    return entry

        with CACHE_LOCK:
            STATS["spawn_calls"] += 1

        target_node = os.environ.get("DEFAULT_TARGET_NODE", "")
        cmd = [SPAWN_SCRIPT, "--user", username]
        if target_node:
            cmd.extend(["--node", target_node])

        spawn_proc = subprocess.run(cmd, capture_output=True, text=True, timeout=45)
        if spawn_proc.returncode != 0:
            raise RuntimeError(f"login-spawn.sh failed: {spawn_proc.stderr.strip()}")

        out = spawn_proc.stdout.strip().splitlines()[-1]
        jid, node, port_str, fp_raw = out.split("|", 3)
        entry = {
            "jobid": jid,
            "node": node,
            "port": int(port_str),
            "fp": fp_raw,
            "updated_at": time.time(),
        }
        with CACHE_LOCK:
            CACHE[username] = entry
        save_route_file(username, entry)
        return entry


def normalize_key(line: str) -> str:
    parts = line.strip().split()
    return " ".join(parts[:2]) if len(parts) >= 2 else line.strip()


def check_authorized_pubkey(username: str, pubkey_obj) -> bool:
    if isinstance(pubkey_obj, dict):
        offered = pubkey_obj.get("publicKey", "").strip()
    else:
        offered = str(pubkey_obj).strip()
    if not offered:
        return False
    offered_key = normalize_key(offered)

    if os.path.exists(CLIENT_AUTHKEYS_PATH):
        try:
            with open(CLIENT_AUTHKEYS_PATH, "r", encoding="utf-8") as fh:
                for line in fh:
                    line = line.strip()
                    if line and not line.startswith("#") and normalize_key(line) == offered_key:
                        return True
        except OSError:
            pass

    if os.path.exists("/usr/bin/sss_ssh_authorizedkeys"):
        try:
            proc = subprocess.run(
                ["/usr/bin/sss_ssh_authorizedkeys", username],
                capture_output=True,
                text=True,
                timeout=5,
            )
            for line in proc.stdout.splitlines():
                line = line.strip()
                if line and not line.startswith("#") and normalize_key(line) == offered_key:
                    return True
        except Exception:
            pass

    return False


class WebhookHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        pass

    def _send_json(self, status: int, payload: dict):
        body = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _read_json(self) -> dict:
        length = int(self.headers.get("Content-Length", "0"))
        raw = self.rfile.read(length) if length > 0 else b"{}"
        return json.loads(raw.decode("utf-8"))

    def do_GET(self):
        if self.path == "/stats":
            with CACHE_LOCK:
                payload = {"stats": dict(STATS), "cache": dict(CACHE)}
            self._send_json(200, payload)
        elif self.path == "/healthz":
            self._send_json(200, {"ok": True})
        else:
            self._send_json(404, {"error": "not found"})

    def do_POST(self):
        if self.path == "/cache/clear":
            with CACHE_LOCK:
                CACHE.clear()
                for k in STATS:
                    STATS[k] = 0
            self._send_json(200, {"cleared": True})
            return

        req = self._read_json()
        username = req.get("username", "")

        if self.path == "/pubkey":
            with CACHE_LOCK:
                STATS["pubkey_requests"] += 1
            ok = bool(username) and check_authorized_pubkey(username, req.get("publicKey", ""))
            self._send_json(200, {
                "remoteAddress": req.get("remoteAddress", "127.0.0.1:22"),
                "connectionId": req.get("connectionId", ""),
                "clientVersion": req.get("clientVersion", ""),
                "username": username,
                "authenticatedUsername": username if ok else "",
                "success": ok,
            })
            return

        if self.path == "/authz":
            with CACHE_LOCK:
                STATS["authz_requests"] += 1
            try:
                resolve_or_spawn_backend(username)
                ok = True
            except Exception as exc:
                sys.stderr.write(f"[webhook] authz spawn error for {username}: {exc}\n")
                ok = False
            self._send_json(200, {
                "remoteAddress": req.get("remoteAddress", "127.0.0.1:22"),
                "connectionId": req.get("connectionId", ""),
                "clientVersion": req.get("clientVersion", ""),
                "username": username,
                "authenticatedUsername": username if ok else "",
                "success": ok,
            })
            return

        if self.path == "/config":
            with CACHE_LOCK:
                STATS["config_requests"] += 1
            try:
                entry = resolve_or_spawn_backend(username)
            except Exception as exc:
                sys.stderr.write(f"[webhook] config error for {username}: {exc}\n")
                self._send_json(500, {"error": str(exc)})
                return

            self._send_json(200, {
                "remoteAddress": req.get("remoteAddress", "127.0.0.1:22"),
                "connectionId": req.get("connectionId", ""),
                "clientVersion": req.get("clientVersion", ""),
                "username": username,
                "authenticatedUsername": req.get("authenticatedUsername", username),
                "config": {
                    "backend": "sshproxy",
                    "sshproxy": {
                        "server": entry["node"],
                        "port": int(entry["port"]),
                        "username": username,
                        "privateKey": PROXY_PRIVKEY_PATH,
                        "allowedHostKeyFingerprints": [clean_fingerprint(entry["fp"])],
                        "hostKeyAlgos": ["ssh-ed25519"],
                    },
                },
            })
            return

        self._send_json(404, {"error": "not found"})


def main():
    server = ThreadingHTTPServer((LISTEN_HOST, LISTEN_PORT), WebhookHandler)
    sys.stderr.write(f"[webhook] Listening on http://{LISTEN_HOST}:{LISTEN_PORT}\n")
    server.serve_forever()


if __name__ == "__main__":
    main()
