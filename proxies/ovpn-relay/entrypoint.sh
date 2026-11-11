#!/bin/bash
set -e

ulimit -n 65535 || true

OVPN_UPSTREAM_HOST="${OVPN_UPSTREAM_HOST:-}"
OVPN_UPSTREAM_PORT="${OVPN_UPSTREAM_PORT:-1194}"

start_bridge() {
    python3 -u /opt/ws_bridge.py 2223 "$OVPN_UPSTREAM_HOST" "$OVPN_UPSTREAM_PORT" ovpn &
    BRIDGE_PID=$!
}

start_cert() {
    python3 -u /opt/cert_server.py &
    CERT_PID=$!
}

BRIDGE_PID=""
CERT_PID=""

# nginx starts LAST, once the bridge accepts connections (no 502/503 window).
wait_port() {
    local port="$1" tries="${2:-60}" i
    for ((i = 0; i < tries; i++)); do
        (exec 3<>"/dev/tcp/127.0.0.1/${port}") 2>/dev/null && return 0
        sleep 0.25
    done
    echo "[!] port ${port} did not come up in time - starting nginx anyway"
    return 1
}

if [ -z "$OVPN_UPSTREAM_HOST" ]; then
    echo "[!] OVPN_UPSTREAM_HOST is not set - /saeka-ovpn disabled."
    echo "[!] Set it to the VM running OpenVPN."
else
    echo "[+] Relaying /saeka-ovpn -> ${OVPN_UPSTREAM_HOST}:${OVPN_UPSTREAM_PORT}"
    start_bridge
fi

start_cert

cleanup() {
    echo "[+] Shutting down background processes..."
    [ -n "$BRIDGE_PID" ] && kill -TERM "$BRIDGE_PID" 2>/dev/null || true
    [ -n "$CERT_PID" ] && kill -TERM "$CERT_PID" 2>/dev/null || true
    exit 0
}
trap cleanup SIGTERM SIGINT

(
  while true; do
    sleep 10
    if [ -n "$BRIDGE_PID" ]; then
        kill -0 "$BRIDGE_PID" 2>/dev/null || { echo "[watchdog] bridge died - restarting..."; start_bridge; }
    fi
    if [ -n "$CERT_PID" ]; then
        kill -0 "$CERT_PID" 2>/dev/null || { echo "[watchdog] cert server died - restarting..."; start_cert; }
    fi
  done
) &

[ -z "$BRIDGE_PID" ] || wait_port 2223 || true
echo "[+] Starting Nginx..."
exec nginx -g "daemon off;"
