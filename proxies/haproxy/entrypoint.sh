#!/bin/bash
set -e
ulimit -n 65535 || true

ADS_MODE="${ADS_MODE:-noads}"
if [ "$ADS_MODE" == "ads" ]; then
    cp /etc/xray/config-ads.json /etc/xray/config.json
else
    cp /etc/xray/config-noads.json /etc/xray/config.json
fi
echo "[+] Ads mode: $ADS_MODE"

echo "[+] Starting Xray Core..."
xray run -config /etc/xray/config.json &
XRAY_PID=$!

echo "[+] Starting haproxy..."
haproxy -f /usr/local/etc/haproxy/haproxy.cfg -db &
ENGINE_PID=$!

trap 'echo "[+] Shutting down..."; kill "$XRAY_PID" "$ENGINE_PID" 2>/dev/null; wait; exit 0' TERM INT

while true; do
    sleep 10
    if ! kill -0 "$XRAY_PID" 2>/dev/null; then
        echo "[watchdog] xray died, restarting..."
        xray run -config /etc/xray/config.json &
        XRAY_PID=$!
    fi
    if ! kill -0 "$ENGINE_PID" 2>/dev/null; then
        echo "[watchdog] haproxy died, restarting..."
        haproxy -f /usr/local/etc/haproxy/haproxy.cfg -db &
        ENGINE_PID=$!
    fi
done
