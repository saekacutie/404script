#!/bin/bash
set -euo pipefail
ulimit -n 65535 2>/dev/null || true

UDPGW_PORT="${UDPGW_PORT:-7300}"
SSH_USERS="${SSH_USERS:-}"          # "user1:pass1,user2:pass2"
NGX=/etc/nginx

# ---------------------------------------------------------------- users
# No users supplied: create one random account and print it to the logs.
if [ -z "$SSH_USERS" ]; then
    gen_pass="$(python3 -c 'import secrets,string; a=string.ascii_letters+string.digits; print("".join(secrets.choice(a) for _ in range(16)))')"
    SSH_USERS="saeka:${gen_pass}"
    echo "[!] SSH_USERS not set - generated one-off account  saeka / ${gen_pass}"
fi
export SSH_USERS   # cert_server.py reads the same list

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

# ---------------------------------------------------- OpenVPN relay (optional)
OVPN_HOST="${OVPN_UPSTREAM_HOST:-}"
OVPN_PORT="${OVPN_UPSTREAM_PORT:-1194}"
if [ -n "$OVPN_HOST" ]; then
    if ! [[ "$OVPN_HOST" =~ ^[A-Za-z0-9.-]+$ ]]; then
        echo "[!] OVPN_UPSTREAM_HOST is not a valid IP or hostname" >&2
        exit 1
    fi
    if ! [[ "$OVPN_PORT" =~ ^[0-9]+$ ]] || [ "$OVPN_PORT" -lt 1 ] || [ "$OVPN_PORT" -gt 65535 ]; then
        echo "[!] OVPN_UPSTREAM_PORT must be 1-65535" >&2
        exit 1
    fi
fi

# ------------------------------------------ XHTTP relay to the VM (optional)
# nginx cannot substitute env vars, so the upstream/location snippets are
# generated here and pulled in by the "include" lines in nginx.conf.
XH_HOST="${XHTTP_UPSTREAM_HOST:-}"
XH_PORT="${XHTTP_UPSTREAM_PORT:-8443}"
XH_PATH="${XHTTP_PATH:-/vless-saeka-xh}"
XH_CERT_B64="${XHTTP_RELAY_CERT_B64:-}"

: > "$NGX/relay-upstream.conf"
: > "$NGX/relay-location.conf"
if [ -n "$XH_HOST" ]; then
    if ! [[ "$XH_HOST" =~ ^[A-Za-z0-9.-]+$ ]]; then
        echo "[!] XHTTP_UPSTREAM_HOST is not a valid IP or hostname" >&2
        exit 1
    fi
    if ! [[ "$XH_PORT" =~ ^[0-9]+$ ]] || [ "$XH_PORT" -lt 1 ] || [ "$XH_PORT" -gt 65535 ]; then
        echo "[!] XHTTP_UPSTREAM_PORT must be 1-65535" >&2
        exit 1
    fi
    if ! [[ "$XH_PATH" =~ ^/[A-Za-z0-9._~/-]*$ ]] || [ "$XH_PATH" = "/" ]; then
        echo "[!] XHTTP_PATH must start with / and use only letters, digits and . _ ~ / -" >&2
        exit 1
    fi
    if [ -z "$XH_CERT_B64" ]; then
        echo "[!] XHTTP_RELAY_CERT_B64 is required (the VM's self-signed cert, base64)" >&2
        exit 1
    fi
    printf '%s' "$XH_CERT_B64" | base64 -d > "$NGX/vm-relay.pem" 2>/dev/null || true
    if ! grep -q 'BEGIN CERTIFICATE' "$NGX/vm-relay.pem"; then
        echo "[!] XHTTP_RELAY_CERT_B64 is not a valid PEM certificate" >&2
        exit 1
    fi

    cat > "$NGX/relay-upstream.conf" <<EOF
upstream xhttp_vm {
    server ${XH_HOST}:${XH_PORT};
    keepalive 128;
    keepalive_timeout 300s;
}
EOF

    # TLS to the VM is verified against the pinned self-signed certificate.
    cat > "$NGX/relay-location.conf" <<EOF
location ${XH_PATH} {
    proxy_pass https://xhttp_vm;
    proxy_http_version 1.1;
    proxy_set_header Connection "";
    proxy_set_header Host \$host;
    proxy_ssl_server_name on;
    proxy_ssl_name vm-relay;
    proxy_ssl_verify on;
    proxy_ssl_verify_depth 2;
    proxy_ssl_trusted_certificate ${NGX}/vm-relay.pem;
    proxy_ssl_protocols TLSv1.2 TLSv1.3;
    proxy_connect_timeout 10s;
    proxy_read_timeout 86400s;
    proxy_send_timeout 86400s;
    proxy_buffering off;
    proxy_request_buffering off;
    client_max_body_size 0;
}
EOF
    echo "[+] Relaying ${XH_PATH} -> https://${XH_HOST}:${XH_PORT} (pinned self-signed cert)"
fi

# ------------------------------------------------------------- SSH host keys
# RSA + ECDSA + ED25519 so old and new clients can all connect.
mkdir -p /etc/dropbear
[ -s /etc/dropbear/dropbear_rsa_host_key ]     || dropbearkey -t rsa -s 2048 -f /etc/dropbear/dropbear_rsa_host_key >/dev/null
[ -s /etc/dropbear/dropbear_ecdsa_host_key ]   || dropbearkey -t ecdsa -s 256 -f /etc/dropbear/dropbear_ecdsa_host_key >/dev/null
[ -s /etc/dropbear/dropbear_ed25519_host_key ] || dropbearkey -t ed25519 -f /etc/dropbear/dropbear_ed25519_host_key >/dev/null

# --------------------------------------------------------------- services
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

# HTTP-Upgrade handshake -> raw TCP, for the SSH path
BRIDGE_LISTEN_PORT=2222 BRIDGE_TARGET_HOST=127.0.0.1 BRIDGE_TARGET_PORT=2200 \
    python3 /opt/ws_bridge.py &
pids+=($!)

# ...and for the OpenVPN path, only when a VM address was given
if [ -n "$OVPN_HOST" ]; then
    echo "[+] Relaying /saeka-ovpn -> ${OVPN_HOST}:${OVPN_PORT}"
    BRIDGE_LISTEN_PORT=2223 BRIDGE_TARGET_HOST="$OVPN_HOST" BRIDGE_TARGET_PORT="$OVPN_PORT" \
        python3 /opt/ws_bridge.py &
    pids+=($!)
fi

# /cert: answers 503 unless both OVPN_PROFILE_B64 and users exist
python3 /opt/cert_server.py &
pids+=($!)

nginx -g 'daemon off;' &
pids+=($!)

# If any service dies, exit so Cloud Run starts a fresh instance
wait -n || true
echo "[!] a service exited - shutting down" >&2
exit 1
