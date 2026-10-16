#!/usr/bin/env python3
"""Serves the OpenVPN client profile at /cert behind HTTP Basic auth.

Logins are the same user:pass list the SSH gateway uses (SSH_USERS). The
profile comes from OVPN_PROFILE_B64. Without both, /cert answers 503 and never
serves anything. nginx proxies /cert here; this listens on 127.0.0.1 only.
"""
import base64
import binascii
import hmac
import logging
import os
import subprocess
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(os.environ.get("CERT_PORT", "2224"))

# ---------------------------------------------------------------- logging
COLORS = {"INFO": "\033[1;32m", "WARNING": "\033[1;33m", "ERROR": "\033[1;31m"}
RESET = "\033[0m"
USE_COLOR = sys.stderr.isatty() or os.environ.get("FORCE_COLOR") == "1"


class ColorFormatter(logging.Formatter):
    def format(self, record):
        msg = super().format(record)
        if not USE_COLOR:
            return msg
        return f"{COLORS.get(record.levelname, '')}{msg}{RESET}"


_handler = logging.StreamHandler(sys.stderr)
_handler.setFormatter(ColorFormatter("%(asctime)s cert_server [%(levelname)s] %(message)s", "%H:%M:%S"))
log = logging.getLogger("cert_server")
log.setLevel(os.environ.get("CERT_LOG_LEVEL", "INFO").upper())
log.addHandler(_handler)
log.propagate = False


def load_users(raw, hashed_raw):
    users = {}
    for entry in hashed_raw.split(","):
        name, separator, encoded = entry.partition(":")
        if separator and name and encoded.startswith("$6$"):
            users[name] = encoded
    if users:
        return users
    for entry in raw.split(","):
        name, sep, password = entry.partition(":")
        if sep and name and password:
            users[name] = password
    return users


USERS = load_users(os.environ.get("SSH_USERS", ""), os.environ.get("CERT_USERS_HASHED", ""))
try:
    PROFILE = base64.b64decode(os.environ.get("OVPN_PROFILE_B64", ""), validate=True)
except (binascii.Error, ValueError):
    PROFILE = b""

if not USERS:
    log.warning("SSH_USERS is empty - /cert will answer 503 until users exist")
if not PROFILE:
    log.warning("OVPN_PROFILE_B64 is empty - /cert will answer 503 until a profile is set")
if USERS and PROFILE:
    log.info("ready: %d user(s), profile is %d bytes", len(USERS), len(PROFILE))


def authorised(header):
    if not header.startswith("Basic "):
        return False, None
    try:
        user, _, password = base64.b64decode(header[6:]).decode().partition(":")
    except Exception:
        return False, None
    expected = USERS.get(user)
    # Always run one comparison so response time doesn't reveal which names exist.
    if isinstance(expected, str) and expected.startswith("$6$"):
        salt = expected.split("$", 3)[2]
        try:
            candidate = subprocess.run(
                ["openssl", "passwd", "-6", "-salt", salt, "-stdin"],
                input=password, text=True, capture_output=True, timeout=2, check=True,
            ).stdout.strip()
        except (OSError, subprocess.SubprocessError):
            candidate = ""
        same = hmac.compare_digest(candidate, expected)
    else:
        same = hmac.compare_digest((expected or "x" * 16).encode(), password.encode())
    return (same and expected is not None), user


class Handler(BaseHTTPRequestHandler):
    server_version = "gateway"
    sys_version = ""

    def log_message(self, fmt, *args):
        # Route through our own colored logger instead of stderr-by-default.
        log.info("%s - %s", self.address_string(), fmt % args)

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
            log.warning("%s requested /cert but it's not configured (users=%d, profile=%dB)",
                        self.address_string(), len(USERS), len(PROFILE))
            self.reply(503, b"profile not configured", {"Content-Type": "text/plain"})
        else:
            ok, user = authorised(self.headers.get("Authorization", ""))
            if not ok:
                log.warning("%s failed auth for /cert (user=%r)", self.address_string(), user)
                time.sleep(1)
                self.reply(401, b"login required", {
                    "Content-Type": "text/plain",
                    "WWW-Authenticate": 'Basic realm="ovpn profile"',
                })
            else:
                log.info("%s downloaded /cert as %s", self.address_string(), user)
                self.reply(200, PROFILE, {
                    "Content-Type": "application/x-openvpn-profile",
                    "Content-Disposition": 'attachment; filename="saeka.ovpn"',
                })

    do_HEAD = do_GET


if __name__ == "__main__":
    log.info("listening on 127.0.0.1:%d", PORT)
    try:
        ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
    except OSError as exc:
        log.critical("cannot bind 127.0.0.1:%d - %s", PORT, exc)
        raise SystemExit(1)
