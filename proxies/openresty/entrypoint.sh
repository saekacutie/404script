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

declare -A PIDS

start() {
    local name="$1"; shift
    echo "[+] Starting $name..."
    "$@" &
    PIDS[$name]=$!
}

restart() {
    case "$1" in
        xray)   start xray xray run -config /etc/xray/config.json ;;
        engine) start engine /usr/local/openresty/bin/openresty -g "daemon off;" ;;
    esac
}

start xray xray run -config /etc/xray/config.json
start engine /usr/local/openresty/bin/openresty -g "daemon off;"

trap 'echo "[+] Shutting down..."; kill "${PIDS[@]}" 2>/dev/null; wait; exit 0' TERM INT

while true; do
    sleep 10
    for name in "${!PIDS[@]}"; do
        if ! kill -0 "${PIDS[$name]}" 2>/dev/null; then
            echo "[watchdog] $name died, restarting..."
            restart "$name"
        fi
    done
done
