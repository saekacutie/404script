#!/usr/bin/env python3
"""Tiny download endpoint for the OpenVPN client profile.

nginx proxies  GET /cert  ->  127.0.0.1:2224 (this file).

Env:
  OVPN_PROFILE_B64  base64 of the full client .ovpn (embedded at deploy time)
  SSH_USERS         "user1:pass1,user2:pass2" - the same list the SSH side uses;
                    any one of them unlocks /cert via HTTP Basic auth
  CERT_FILENAME     download name (default: saeka.ovpn)

Why auth: the profile contains the client PRIVATE KEY, and a *.run.app URL
is public. Without a login, anyone who guesses /cert gets a working VPN.
"""
import base64, binascii, hmac, os, sys, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = 2224
FILENAME = "".join(c for c in os.environ.get("CERT_FILENAME", "saeka.ovpn")
                   if c.isalnum() or c in "._-") or "saeka.ovpn"

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
    users = {}
    for pair in os.environ.get("SSH_USERS", "").split(","):
        if ":" in pair:
            u, p = pair.split(":", 1)
            if u and p:
                users[u] = p
    return users

PROFILE = load_profile()
USERS = load_users()

def check_auth(header):
    if not header or not header.startswith("Basic "):
        return False
    try:
        user, _, pw = base64.b64decode(header[6:]).decode().partition(":")
    except Exception:
        return False
    ok = False
    for u, p in USERS.items():          # no early exit: constant-ish time
        ok |= hmac.compare_digest(u, user) and hmac.compare_digest(p, pw)
    return ok

class Handler(BaseHTTPRequestHandler):
    server_version = "gw"
    sys_version = ""

    def _send(self, code, body=b"", headers=None):
        self.send_response(code)
        for k, v in (headers or {}).items():
            self.send_header(k, v)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def do_HEAD(self): self.do_GET()

    def do_GET(self):
        if PROFILE is None:
            return self._send(503, b"Profile not configured on this deployment.\n",
                              {"Content-Type": "text/plain"})
        if not USERS:
            return self._send(503, b"No users configured - /cert is locked.\n",
                              {"Content-Type": "text/plain"})
        if not check_auth(self.headers.get("Authorization")):
            time.sleep(1)               # slow down guessing
            return self._send(401, b"Login required.\n", {
                "Content-Type": "text/plain",
                "WWW-Authenticate": 'Basic realm="VPN profile", charset="UTF-8"'})
        # octet-stream + attachment + nosniff: iOS Safari otherwise shows the
        # file as text instead of offering "Open in OpenVPN"; Android imports
        # by the .ovpn extension.
        self._send(200, PROFILE, {
            "Content-Type": "application/octet-stream",
            "Content-Disposition": f'attachment; filename="{FILENAME}"',
            "X-Content-Type-Options": "nosniff"})

    def log_message(self, *a):          # never log Authorization / paths
        pass

if __name__ == "__main__":
    print(f"[cert] /cert {'ENABLED' if PROFILE and USERS else 'disabled'}", flush=True)
    ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
