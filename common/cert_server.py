#!/usr/bin/env python3
import os
import sys
import base64
import logging
from http.server import HTTPServer, BaseHTTPRequestHandler

logging.basicConfig(level=logging.INFO, format="[cert_server] %(asctime)s - %(levelname)s - %(message)s")

PORT = 2224
PROFILE_B64 = os.environ.get("OVPN_PROFILE_B64", "")
SSH_USERS_RAW = os.environ.get("SSH_USERS", "")

ALLOWED_USERS = {}
if SSH_USERS_RAW:
    for entry in SSH_USERS_RAW.split(","):
        if ":" in entry:
            u, p = entry.split(":", 1)
            ALLOWED_USERS[u.strip()] = p.strip()

class CertHandler(BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        logging.info("%s - - [%s] %s" % (self.client_address[0], self.log_date_time_string(), format % args))

    def check_auth(self):
        if not ALLOWED_USERS:
            return True
        auth_header = self.headers.get("Authorization")
        if not auth_header or not auth_header.startswith("Basic "):
            return False
        try:
            encoded = auth_header.split(" ", 1)[1]
            decoded = base64.b64decode(encoded).decode("utf-8")
            user, pwd = decoded.split(":", 1)
            return ALLOWED_USERS.get(user) == pwd
        except Exception:
            return False

    def do_GET(self):
        if self.path != "/cert":
            self.send_response(404)
            self.end_headers()
            self.wfile.write(b"404 Not Found")
            return

        if not self.check_auth():
            self.send_response(401)
            self.send_header("WWW-Authenticate", 'Basic realm="Cert Download"')
            self.end_headers()
            self.wfile.write(b"401 Unauthorized")
            return

        if not PROFILE_B64:
            self.send_response(500)
            self.end_headers()
            self.wfile.write(b"500 OVPN_PROFILE_B64 not set")
            return

        try:
            cert_data = base64.b64decode(PROFILE_B64)
            self.send_response(200)
            self.send_header("Content-Type", "application/x-openvpn-profile")
            self.send_header("Content-Disposition", 'attachment; filename="client.ovpn"')
            self.send_header("Content-Length", str(len(cert_data)))
            self.end_headers()
            self.wfile.write(cert_data)
        except Exception as e:
            self.send_response(500)
            self.end_headers()
            self.wfile.write(f"Error decoding profile: {e}".encode("utf-8"))

def run():
    server = HTTPServer(("0.0.0.0", PORT), CertHandler)
    logging.info(f"Cert server running on port {PORT}")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    server.server_close()

if __name__ == "__main__":
    run()
