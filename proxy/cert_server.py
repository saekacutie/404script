#!/usr/bin/env python3
"""Serves the OpenVPN client profile at /cert behind HTTP Basic Auth.

Credentials are the same SSH_USERS the gateway uses for the SSH tunnel, so
there's a single set of logins for the whole deploy. If no profile was
baked in (OVPN_PROFILE_B64 unset) every authenticated request gets 503;
if no users are configured at all, every request gets 401.
"""
import argparse
import base64
import os
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Optional


def load_users() -> dict:
    users = {}
    for pair in os.environ.get("SSH_USERS", "").split(","):
        pair = pair.strip()
        if not pair or ":" not in pair:
            continue
        uname, pw = pair.split(":", 1)
        users[uname] = pw
    return users


def load_profile() -> Optional[bytes]:
    b64 = os.environ.get("OVPN_PROFILE_B64", "")
    if not b64:
        return None
    try:
        return base64.b64decode(b64)
    except Exception:
        return None


USERS = load_users()
PROFILE = load_profile()


class Handler(BaseHTTPRequestHandler):
    server_version = "cert_server/1.0"

    def log_message(self, fmt, *args):  # noqa: A002 - quiet, nginx already logs
        pass

    def _unauthorized(self):
        self.send_response(401)
        self.send_header("WWW-Authenticate", 'Basic realm="cert"')
        self.end_headers()

    def _check_auth(self) -> bool:
        header = self.headers.get("Authorization", "")
        if not header.startswith("Basic "):
            return False
        try:
            decoded = base64.b64decode(header[6:]).decode("utf-8", "replace")
            uname, _, pw = decoded.partition(":")
        except Exception:
            return False
        return uname in USERS and USERS[uname] == pw

    def do_GET(self):
        if self.path.rstrip("/") != "/cert":
            self.send_response(404)
            self.end_headers()
            return
        if not USERS or not self._check_auth():
            self._unauthorized()
            return
        if PROFILE is None:
            self.send_response(503)
            self.end_headers()
            self.wfile.write(b"no profile configured")
            return
        self.send_response(200)
        self.send_header("Content-Type", "application/x-openvpn-profile")
        self.send_header("Content-Disposition", 'attachment; filename="client1.ovpn"')
        self.send_header("Content-Length", str(len(PROFILE)))
        self.end_headers()
        self.wfile.write(PROFILE)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--listen", required=True, help="host:port to listen on")
    args = parser.parse_args()
    host, port = args.listen.rsplit(":", 1)
    server = ThreadingHTTPServer((host, int(port)), Handler)
    server.serve_forever()


if __name__ == "__main__":
    main()
