#!/bin/bash
set -e
ulimit -n 65535 || true
source /ads-mode.sh

echo "[+] Starting Xray Core..."
xray run -config /etc/xray/config.json & XRAY_PID=$!
echo "[+] Starting traefik..."
traefik --configFile=/etc/traefik/traefik.yml & ENGINE_PID=$!
trap 'kill "$XRAY_PID" "$ENGINE_PID" 2>/dev/null; wait; exit 0' TERM INT
while true; do
    sleep 10
    if ! kill -0 "$XRAY_PID" 2>/dev/null; then source /ads-mode.sh; xray run -config /etc/xray/config.json & XRAY_PID=$!; fi
    if ! kill -0 "$ENGINE_PID" 2>/dev/null; then traefik --configFile=/etc/traefik/traefik.yml & ENGINE_PID=$!; fi
done
