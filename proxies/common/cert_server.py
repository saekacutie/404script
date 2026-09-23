#!/usr/bin/env python3
"""Serve the OpenVPN client profile at /cert behind HTTP Basic auth.

The profile contains a private key, so it is never served without credentials.
The same credentials are accepted from SSH_USERS (the deploy.sh convention) or
OVPN_USERS (useful when deploy_vm.py is run independently).  Environment values
are read for every request so a refreshed Cloud Run instance does not retain a
stale credential snapshot.
"""
import base64
import binascii
import hmac
import os
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(os.environ.get("CERT_PORT", "2224"))
FILENAME = "".join(
    c for c in os.environ.get("CERT_FILENAME", "saeka.ovpn")
    if c.isalnum() or c in "._-"
) or "saeka.ovpn"


def load_profile():
    raw = os.environ.get("OVPN_PROFILE_B64", "").strip()
    if not raw:
        return None
    try:
        data = base64.b64decode(raw, validate=True)
    except (binascii.Error, ValueError):
        print("[cert] OVPN_PROFILE_B64 is not valid base64 - /cert disabled", flush=True)
        return None
    text = data.decode("utf-8", "replace").replace("\r\n", "\n").strip() + "\n"
    if "<ca>" not in text or "remote " not in text:
        print("[cert] profile looks incomplete (no <ca> / remote) - /cert disabled", flush=True)
        return None
    return text.encode()


def load_users():
    # SSH_USERS is the canonical deploy.sh variable. OVPN_USERS is supported
    # for deploy_vm.py-only deployments. Do not concatenate both lists: that
    # could unexpectedly authorize credentials from an unrelated deployment.
    raw = os.environ.get("SSH_USERS", "") or os.environ.get("OVPN_USERS", "")
    users = {}
    for pair in raw.split(","):
        user, sep, password = pair.strip().partition(":")
        if sep and user and password:
            users[user] = password
    return users


def check_auth(header, users):
    if not header or not header.startswith("Basic "):
        return False
    try:
        decoded = base64.b64decode(header[6:], validate=True).decode("utf-8")
        user, separator, password = decoded.partition(":")
    except (binascii.Error, UnicodeDecodeError, ValueError):
        return False
    if not separator:
        return False

    # Compare every entry instead of returning on the first match.
    ok = False
    for expected_user, expected_password in users.items():
        ok |= hmac.compare_digest(expected_user, user) and hmac.compare_digest(
            expected_password, password
        )
    return ok


class Handler(BaseHTTPRequestHandler):
    server_version = "gateway"
    sys_version = ""

    def _send(self, code, body=b"", headers=None):
        self.send_response(code)
        for key, value in (headers or {}).items():
            self.send_header(key, value)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def do_HEAD(self):
        self.do_GET()

    def do_GET(self):
        profile = load_profile()
        users = load_users()
        if profile is None:
            return self._send(
                503,
                b"Profile not configured on this deployment.\n",
                {"Content-Type": "text/plain"},
            )
        if not users:
            return self._send(
                503,
                b"No users configured - /cert is locked.\n",
                {"Content-Type": "text/plain"},
            )
        if not check_auth(self.headers.get("Authorization"), users):
            time.sleep(1)
            return self._send(
                401,
                b"Login required.\n",
                {
                    "Content-Type": "text/plain",
                    "WWW-Authenticate": 'Basic realm="VPN profile", charset="UTF-8"',
                },
            )
        return self._send(
            200,
            profile,
            {
                "Content-Type": "application/octet-stream",
                "Content-Disposition": f'attachment; filename="{FILENAME}"',
                "X-Content-Type-Options": "nosniff",
            },
        )

    def log_message(self, *_args):
        # Never log Authorization headers or request paths.
        pass


if __name__ == "__main__":
    print("[cert] profile server started", flush=True)
    ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
