#!/usr/bin/env python3
"""Serves the OpenVPN client profile at /cert behind HTTP Basic auth.

Logins are the same user:pass list the SSH gateway uses (SSH_USERS). The
profile comes from OVPN_PROFILE_B64. Without both, /cert answers 503 and never
serves anything. nginx proxies /cert here; this listens on 127.0.0.1 only.
"""
import base64
import binascii
import hmac
import os
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(os.environ.get("CERT_PORT", "2224"))


def load_users(raw):
    users = {}
    for entry in raw.split(","):
        name, sep, password = entry.partition(":")
        if sep and name and password:
            users[name] = password
    return users


USERS = load_users(os.environ.get("SSH_USERS", ""))
try:
    PROFILE = base64.b64decode(os.environ.get("OVPN_PROFILE_B64", ""), validate=True)
except (binascii.Error, ValueError):
    PROFILE = b""


def authorised(header):
    if not header.startswith("Basic "):
        return False
    try:
        user, _, password = base64.b64decode(header[6:]).decode().partition(":")
    except Exception:
        return False
    expected = USERS.get(user)
    # Always run one comparison so response time doesn't reveal which names exist.
    same = hmac.compare_digest((expected or "x" * 16).encode(), password.encode())
    return same and expected is not None


class Handler(BaseHTTPRequestHandler):
    server_version = "gateway"
    sys_version = ""

    def log_message(self, *args):
        pass

    def reply(self, code, body=b"", extra=None):
        self.send_response(code)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        for key, value in (extra or {}).items():
            self.send_header(key, value)
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def do_GET(self):
        if self.path.split("?", 1)[0] != "/cert":
            self.reply(404, b"not found", {"Content-Type": "text/plain"})
        elif not PROFILE or not USERS:
            self.reply(503, b"profile not configured", {"Content-Type": "text/plain"})
        elif not authorised(self.headers.get("Authorization", "")):
            time.sleep(1)
            self.reply(401, b"login required", {
                "Content-Type": "text/plain",
                "WWW-Authenticate": 'Basic realm="ovpn profile"',
            })
        else:
            self.reply(200, PROFILE, {
                "Content-Type": "application/x-openvpn-profile",
                "Content-Disposition": 'attachment; filename="saeka.ovpn"',
            })

    do_HEAD = do_GET


if __name__ == "__main__":
    ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
