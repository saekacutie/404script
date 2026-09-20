#!/bin/bash
set -euo pipefail

SSH_USER="${SSH_USER:-saeka}"
SSH_PASS="${SSH_PASS:-}"
UDPGW_PORT="${UDPGW_PORT:-7300}"

if [ -z "$SSH_PASS" ]; then
    echo "ERROR: set the SSH_PASS environment variable" >&2
    exit 1
fi

case "$SSH_USER" in
    ""|[0-9-]*|*[!a-z0-9_-]*)
        echo "ERROR: SSH_USER must be lowercase letters, digits, _ or -, and not start with a digit or -" >&2
        exit 1
        ;;
esac

if ! id "$SSH_USER" >/dev/null 2>&1; then
    useradd -m -s /bin/false "$SSH_USER"
fi
printf '%s:%s\n' "$SSH_USER" "$SSH_PASS" | chpasswd

mkdir -p /etc/dropbear

pids=()
cleanup() {
    trap - EXIT
    kill "${pids[@]}" 2>/dev/null || true
    wait 2>/dev/null || true
}
trap cleanup EXIT
trap 'exit 143' TERM INT

# UDP over SSH: clients forward to 127.0.0.1:${UDPGW_PORT} through the tunnel
badvpn-udpgw \
    --listen-addr "127.0.0.1:${UDPGW_PORT}" \
    --max-clients 1000 \
    --max-connections-for-client 500 \
    --loglevel 2 &
pids+=($!)

# SSH server (Dropbear): password auth, no root login, no remote forwarding
dropbear -F -E -R -w -k -m \
    -p 127.0.0.1:2200 \
    -K 30 -W 65536 \
    -b /etc/dropbear/banner.txt &
pids+=($!)

# WebSocket/Upgrade -> raw TCP bridge
python3 /opt/ws_bridge.py &
pids+=($!)

nginx -g 'daemon off;' &
pids+=($!)

# If any service dies, exit so the platform restarts the whole container
wait -n || true
echo "A service exited; shutting down." >&2
exit 1
