#!/bin/bash
set -e
ulimit -n 65535 || true

# Env:
#   SSH_USERS          "user1:pass1,user2:pass2" (random one-off account if unset)
#   OVPN_UPSTREAM_HOST VM IP/host running OpenVPN (optional; enables /saeka-ovpn)
#   OVPN_UPSTREAM_PORT default 1194 (server must be proto tcp)
#   OVPN_PROFILE_B64   client .ovpn, base64 (optional; enables /cert)
OVPN_UPSTREAM_HOST="${OVPN_UPSTREAM_HOST:-}"
OVPN_UPSTREAM_PORT="${OVPN_UPSTREAM_PORT:-1194}"

# ---- SSH accounts (tunnel-only, /bin/false shell) ---------------------------
if [ -z "${SSH_USERS:-}" ]; then
    RANDPW=$(LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c16 || true)
    SSH_USERS="saeka:${RANDPW}"
    echo "[+] SSH_USERS not set - generated one-off account saeka:${RANDPW} (won't persist across redeploys)"
    export SSH_USERS          # so /cert can use it too
fi
IFS=',' read -ra PAIRS <<< "$SSH_USERS"
for pair in "${PAIRS[@]}"; do
    user="${pair%%:*}"
    pass="${pair#*:}"
    [ -z "$user" ] && continue
    if ! [[ "$user" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then
        echo "[!] Skipping invalid username '${user}'"; continue
    fi
    if [ -z "$pass" ] || [ "$pass" = "$pair" ]; then
        echo "[!] Skipping '${user}' - no password (format user:pass)"; continue
    fi
    id -u "$user" >/dev/null 2>&1 || useradd -m -s /bin/false "$user"
    echo "${user}:${pass}" | chpasswd
    echo "[+] SSH account ready: $user"
done

start_dropbear() {
    dropbear -F -E -R -w -K 60 -p 127.0.0.1:2200 -b /etc/dropbear/banner.txt &
    DROPBEAR_PID=$!
}
start_udpgw() {
    badvpn-udpgw --listen-addr 127.0.0.1:7300 --max-clients 1000 \
        --max-connections-for-client 40 --loglevel warning &
    UDPGW_PID=$!
}
start_ssh_bridge() {
    python3 /opt/ws_bridge.py 2222 127.0.0.1 2200 ssh &
    SSH_BRIDGE_PID=$!
}
start_ovpn_bridge() {
    python3 /opt/ws_bridge.py 2223 "$OVPN_UPSTREAM_HOST" "$OVPN_UPSTREAM_PORT" ovpn &
    OVPN_BRIDGE_PID=$!
}
start_cert() {
    python3 /opt/cert_server.py &
    CERT_PID=$!
}

echo "[+] Starting Dropbear on 127.0.0.1:2200..."
start_dropbear
echo "[+] Starting BadVPN UDPGW on 127.0.0.1:7300..."
start_udpgw
echo "[+] /saeka-ssh -> Dropbear"
start_ssh_bridge

OVPN_BRIDGE_PID=""
if [ -n "$OVPN_UPSTREAM_HOST" ]; then
    echo "[+] /saeka-ovpn -> ${OVPN_UPSTREAM_HOST}:${OVPN_UPSTREAM_PORT}"
    start_ovpn_bridge
else
    echo "[!] OVPN_UPSTREAM_HOST not set - /saeka-ovpn disabled (SSH unaffected)."
fi
start_cert

echo "[+] Starting watchdog..."
(
  while true; do
    sleep 10
    kill -0 "$DROPBEAR_PID"    2>/dev/null || { echo "[watchdog] dropbear died";    start_dropbear; }
    kill -0 "$UDPGW_PID"       2>/dev/null || { echo "[watchdog] udpgw died";        start_udpgw; }
    kill -0 "$SSH_BRIDGE_PID"  2>/dev/null || { echo "[watchdog] ssh bridge died";   start_ssh_bridge; }
    kill -0 "$CERT_PID"        2>/dev/null || { echo "[watchdog] cert server died";  start_cert; }
    if [ -n "$OVPN_BRIDGE_PID" ]; then
        kill -0 "$OVPN_BRIDGE_PID" 2>/dev/null || { echo "[watchdog] ovpn bridge died"; start_ovpn_bridge; }
    fi
  done
) &

echo "[+] Starting nginx..."
exec nginx -g "daemon off;"
