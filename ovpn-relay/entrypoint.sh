#!/bin/bash
set -e
ulimit -n 65535 || true

# Env:
#   OVPN_UPSTREAM_HOST VM IP/host running OpenVPN (proto tcp)
#   OVPN_UPSTREAM_PORT default 1194
#   OVPN_PROFILE_B64   client .ovpn, base64 (enables /cert)
#   SSH_USERS          "user:pass,..." - login for /cert (same list as the ssh engine)
OVPN_UPSTREAM_HOST="${OVPN_UPSTREAM_HOST:-}"
OVPN_UPSTREAM_PORT="${OVPN_UPSTREAM_PORT:-1194}"

start_bridge() {
    python3 /opt/ws_bridge.py 2223 "$OVPN_UPSTREAM_HOST" "$OVPN_UPSTREAM_PORT" ovpn &
    BRIDGE_PID=$!
}
start_cert() {
    python3 /opt/cert_server.py &
    CERT_PID=$!
}

BRIDGE_PID=""
if [ -z "$OVPN_UPSTREAM_HOST" ]; then
    echo "[!] OVPN_UPSTREAM_HOST is not set - /saeka-ovpn disabled."
    echo "[!] Set it to the VM running OpenVPN (see deploy_vm.py)."
else
    echo "[+] Relaying /saeka-ovpn -> ${OVPN_UPSTREAM_HOST}:${OVPN_UPSTREAM_PORT}"
    start_bridge
fi
start_cert

(
  while true; do
    sleep 10
    if [ -n "$BRIDGE_PID" ]; then
        kill -0 "$BRIDGE_PID" 2>/dev/null || { echo "[watchdog] bridge died"; start_bridge; }
    fi
    kill -0 "$CERT_PID" 2>/dev/null || { echo "[watchdog] cert server died"; start_cert; }
  done
) &

echo "[+] Starting nginx..."
exec nginx -g "daemon off;"
