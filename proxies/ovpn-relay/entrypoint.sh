#!/bin/bash
set -euo pipefail
ulimit -n 65535 2>/dev/null || true

HOST="${OVPN_UPSTREAM_HOST:-}"
PORT="${OVPN_UPSTREAM_PORT:-1194}"

if [ -z "$HOST" ]; then
    echo "[!] OVPN_UPSTREAM_HOST is not set (static IP of the OpenVPN VM)" >&2
    exit 1
fi
if ! [[ "$HOST" =~ ^[A-Za-z0-9.-]+$ ]]; then
    echo "[!] OVPN_UPSTREAM_HOST is not a valid IP or hostname" >&2
    exit 1
fi
if ! [[ "$PORT" =~ ^[0-9]+$ ]] || [ "$PORT" -lt 1 ] || [ "$PORT" -gt 65535 ]; then
    echo "[!] OVPN_UPSTREAM_PORT must be 1-65535" >&2
    exit 1
fi
echo "[+] Relaying /saeka-ovpn -> ${HOST}:${PORT}"

pids=()
cleanup() {
    trap - EXIT
    kill "${pids[@]}" 2>/dev/null || true
    wait 2>/dev/null || true
}
trap cleanup EXIT
trap 'exit 143' TERM INT

BRIDGE_LISTEN_PORT=2223 BRIDGE_TARGET_HOST="$HOST" BRIDGE_TARGET_PORT="$PORT" \
    python3 /opt/ws_bridge.py &
pids+=($!)

nginx -g 'daemon off;' &
pids+=($!)

wait -n || true
echo "[!] a service exited - shutting down" >&2
exit 1
