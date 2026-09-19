#!/bin/bash
set -e
ulimit -n 65535 || true
source /usr/local/bin/ssh-ws.sh

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

echo "[+] Starting openresty..."
/usr/local/openresty/bin/openresty -g 'daemon off;' &
ENGINE_PID=$!

ssh_ws_start || echo "[!] SSH-WS failed to start (continuing without it)"

trap 'echo "[+] Shutting down..."; kill "$XRAY_PID" "$ENGINE_PID" $(ssh_ws_pids) 2>/dev/null; wait; exit 0' TERM INT

while true; do
    sleep 10
    if ! kill -0 "$XRAY_PID" 2>/dev/null; then
        echo "[watchdog] xray died, restarting..."
        xray run -config /etc/xray/config.json &
        XRAY_PID=$!
    fi
    if ! kill -0 "$ENGINE_PID" 2>/dev/null; then
        echo "[watchdog] openresty died, restarting..."
        /usr/local/openresty/bin/openresty -g 'daemon off;' &
        ENGINE_PID=$!
    fi
    ssh_ws_watch || true
done
