#!/bin/bash
set -e
ulimit -n 65535 || true

source /ads-mode.sh

echo "[+] Starting Xray Core..."
xray run -config /etc/xray/config.json &
XRAY_PID=$!

echo "[+] Starting caddy..."
caddy run --config /etc/caddy/Caddyfile --adapter caddyfile &
ENGINE_PID=$!

trap 'echo "[+] Shutting down..."; kill "$XRAY_PID" "$ENGINE_PID" 2>/dev/null; wait; exit 0' TERM INT

while true; do
    sleep 10
    if ! kill -0 "$XRAY_PID" 2>/dev/null; then
        echo "[watchdog] xray died, restarting..."
        source /ads-mode.sh
        xray run -config /etc/xray/config.json &
        XRAY_PID=$!
    fi
    if ! kill -0 "$ENGINE_PID" 2>/dev/null; then
        echo "[watchdog] caddy died, restarting..."
        caddy run --config /etc/caddy/Caddyfile --adapter caddyfile &
        ENGINE_PID=$!
    fi
done
