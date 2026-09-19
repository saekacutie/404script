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

# SSH-over-WebSocket credentials. Override these at deployment time with
# SSH_USER and SSH_PASSWORD; defaults preserve the documented saeka:saeka UI.
SSH_USER="${SSH_USER:-saeka}"
SSH_PASSWORD="${SSH_PASSWORD:-saeka}"
if ! id "$SSH_USER" >/dev/null 2>&1; then
    adduser -D -s /bin/ash "$SSH_USER"
fi
printf '%s:%s\n' "$SSH_USER" "$SSH_PASSWORD" | chpasswd
mkdir -p /run/sshd
ssh-keygen -A >/dev/null 2>&1
cat > /etc/ssh/sshd_config.d/saeka.conf <<EOF
Port 22
ListenAddress 127.0.0.1
PasswordAuthentication yes
KbdInteractiveAuthentication no
PermitRootLogin no
AllowUsers ${SSH_USER}
AllowTcpForwarding yes
X11Forwarding no
PermitTunnel no
GatewayPorts no
EOF
/usr/sbin/sshd

python3 /ssh-bridge.py &
BRIDGE_PID=$!
echo "[+] SSH WebSocket bridge ready at /saeka-ssh (user: ${SSH_USER})"

echo "[+] Starting Xray Core..."
xray run -config /etc/xray/config.json &
XRAY_PID=$!

echo "[+] Starting openresty..."
/usr/local/openresty/bin/openresty -g 'daemon off;' &
ENGINE_PID=$!

cleanup() {
    echo "[+] Shutting down..."
    kill "$BRIDGE_PID" "$XRAY_PID" "$ENGINE_PID" 2>/dev/null || true
    wait || true
    exit 0
}
trap cleanup TERM INT

while true; do
    sleep 10
    if ! kill -0 "$BRIDGE_PID" 2>/dev/null; then
        echo "[watchdog] SSH bridge died, restarting..."
        python3 /ssh-bridge.py & BRIDGE_PID=$!
    fi
    if ! kill -0 "$XRAY_PID" 2>/dev/null; then
        echo "[watchdog] xray died, restarting..."
        xray run -config /etc/xray/config.json & XRAY_PID=$!
    fi
    if ! kill -0 "$ENGINE_PID" 2>/dev/null; then
        echo "[watchdog] openresty died, restarting..."
        /usr/local/openresty/bin/openresty -g 'daemon off;' & ENGINE_PID=$!
    fi
done
