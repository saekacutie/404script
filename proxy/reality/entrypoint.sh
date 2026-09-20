#!/bin/bash
set -euo pipefail

log() { echo "[entrypoint] $*" >&2; }

IFS=',' read -ra USER_PAIRS <<< "${SSH_USERS:-}"
for pair in "${USER_PAIRS[@]}"; do
    [ -z "$pair" ] && continue
    uname="${pair%%:*}"
    pass="${pair#*:}"
    if ! id "$uname" >/dev/null 2>&1; then
        useradd -M -N -s /bin/false "$uname"
        log "created tunnel-only user: $uname"
    fi
    echo "${uname}:${pass}" | chpasswd
done

mkdir -p /etc/dropbear
[ -f /etc/dropbear/dropbear_rsa_host_key ] || dropbearkey -t rsa -f /etc/dropbear/dropbear_rsa_host_key -s 2048
[ -f /etc/dropbear/dropbear_ecdsa_host_key ] || dropbearkey -t ecdsa -f /etc/dropbear/dropbear_ecdsa_host_key
dropbear -r /etc/dropbear/dropbear_rsa_host_key -r /etc/dropbear/dropbear_ecdsa_host_key -p 127.0.0.1:2200 -b /etc/dropbear/banner.txt -F &
badvpn-udpgw --listen-addr 127.0.0.1:7300 --max-clients 128 &
python3 /opt/ws_bridge.py --listen 127.0.0.1:2222 --target 127.0.0.1:2200 &

: > /etc/nginx/relay-upstream.conf
: > /etc/nginx/relay-location.conf

if [ -n "${OVPN_UPSTREAM_HOST:-}" ]; then
    python3 /opt/ws_bridge.py --listen 127.0.0.1:2223 --target "${OVPN_UPSTREAM_HOST}:${OVPN_UPSTREAM_PORT:-1194}" &
    cat >> /etc/nginx/relay-upstream.conf <<EOF
upstream ovpn_ws_backend { server 127.0.0.1:2223; }
EOF
    cat >> /etc/nginx/relay-location.conf <<'EOF'
location /saeka-ovpn {
    proxy_pass http://ovpn_ws_backend;
    proxy_http_version 1.1;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection $connection_upgrade;
    proxy_set_header Host $host;
    proxy_read_timeout 3600s;
    proxy_send_timeout 3600s;
}
EOF
fi

if [ -n "${XHTTP_UPSTREAM_HOST:-}" ]; then
    if [ -n "${XHTTP_RELAY_CERT_B64:-}" ]; then
        printf '%s' "${XHTTP_RELAY_CERT_B64}" | base64 -d > /etc/nginx/xhttp-pin.pem
    else
        : > /etc/nginx/xhttp-pin.pem
    fi
    cat >> /etc/nginx/relay-upstream.conf <<EOF
upstream xhttp_backend { server ${XHTTP_UPSTREAM_HOST}:${XHTTP_UPSTREAM_PORT:-8443}; }
EOF
    cat >> /etc/nginx/relay-location.conf <<EOF
location ${XHTTP_PATH:-/xhttp} {
    proxy_pass https://xhttp_backend;
    proxy_ssl_trusted_certificate /etc/nginx/xhttp-pin.pem;
    proxy_ssl_verify on;
    proxy_ssl_server_name on;
    proxy_ssl_name vm-relay;
    proxy_http_version 1.1;
    proxy_set_header Host \$host;
    proxy_read_timeout 3600s;
    proxy_send_timeout 3600s;
}
EOF
fi

python3 /opt/cert_server.py --listen 127.0.0.1:2224 &
nginx -t
exec nginx -g 'daemon off;'
