#!/bin/bash
set -euo pipefail
ulimit -n 65535 2>/dev/null || true

UDPGW_PORT="${UDPGW_PORT:-7300}"
SSH_USERS="${SSH_USERS:-}"   # "user1:pass1,user2:pass2"

# No users supplied: create one random account and print it to the logs
if [ -z "$SSH_USERS" ]; then
    gen_pass="$(python3 -c 'import secrets,string; a=string.ascii_letters+string.digits; print("".join(secrets.choice(a) for _ in range(16)))')"
    SSH_USERS="saeka:${gen_pass}"
    echo "[!] SSH_USERS not set - generated one-off account  saeka / ${gen_pass}"
fi

created=0
IFS=',' read -r -a entries <<< "$SSH_USERS"
for entry in "${entries[@]}"; do
    name="${entry%%:*}"
    pass="${entry#*:}"
    if [ "$name" = "$entry" ] || [ -z "$pass" ] || ! [[ "$name" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then
        echo "[!] skipping invalid SSH_USERS entry (expected name:password, name = a-z 0-9 _ -)" >&2
        continue
    fi
    uid="$(id -u "$name" 2>/dev/null || true)"
    if [ -n "$uid" ] && [ "$uid" -lt 1000 ]; then
        echo "[!] skipping '$name': system account" >&2
        continue
    fi
    if [ -z "$uid" ]; then
        useradd -m -s /bin/false "$name"
    fi
    printf '%s:%s\n' "$name" "$pass" | chpasswd
    created=$((created + 1))
    echo "[+] user ready: ${name}"
done
if [ "$created" -eq 0 ]; then
    echo "[!] no valid users - refusing to start" >&2
    exit 1
fi

# Host keys (RSA + ECDSA + ED25519 so old and new clients can all connect)
mkdir -p /etc/dropbear
[ -s /etc/dropbear/dropbear_rsa_host_key ]     || dropbearkey -t rsa -s 2048 -f /etc/dropbear/dropbear_rsa_host_key >/dev/null
[ -s /etc/dropbear/dropbear_ecdsa_host_key ]   || dropbearkey -t ecdsa -s 256 -f /etc/dropbear/dropbear_ecdsa_host_key >/dev/null
[ -s /etc/dropbear/dropbear_ed25519_host_key ] || dropbearkey -t ed25519 -f /etc/dropbear/dropbear_ed25519_host_key >/dev/null

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

# SSH server: password login, no root, no remote forwarding
dropbear -F -E -w -k -m \
    -p 127.0.0.1:2200 \
    -r /etc/dropbear/dropbear_rsa_host_key \
    -r /etc/dropbear/dropbear_ecdsa_host_key \
    -r /etc/dropbear/dropbear_ed25519_host_key \
    -K 30 -W 65536 \
    -b /etc/dropbear/banner.txt &
pids+=($!)

BRIDGE_LISTEN_PORT=2222 BRIDGE_TARGET_HOST=127.0.0.1 BRIDGE_TARGET_PORT=2200 \
    python3 /opt/ws_bridge.py &
pids+=($!)

nginx -g 'daemon off;' &
pids+=($!)

# If any service dies, exit so Cloud Run starts a fresh instance
wait -n || true
echo "[!] a service exited - shutting down" >&2
exit 1
