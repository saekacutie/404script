#!/bin/bash
# Wires up the pieces the Dockerfile's header comment describes:
#   /saeka-ssh  -> ws_bridge :2222 -> Dropbear :2200 (+ badvpn-udpgw :7300)
#   /saeka-ovpn -> ws_bridge :2223 -> OVPN_UPSTREAM_HOST:OVPN_UPSTREAM_PORT   (optional)
#   /cert       -> cert_server :2224
#   XHTTP_PATH  -> https://XHTTP_UPSTREAM_HOST:XHTTP_UPSTREAM_PORT (pinned)  (optional)
set -euo pipefail

log() { echo "[entrypoint] $*" >&2; }

# ---- SSH users -> real system accounts, for Dropbear password auth --------
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

# ---- Dropbear (the actual SSH server, loopback-only) -----------------------
mkdir -p /etc/dropbear
[ -f /etc/dropbear/dropbear_rsa_host_key ] || dropbearkey -t rsa -f /etc/dropbear/dropbear_rsa_host_key -s 2048
[ -f /etc/dropbear/dropbear_ecdsa_host_key ] || dropbearkey -t ecdsa -f /etc/dropbear/dropbear_ecdsa_host_key
dropbear \
    -r /etc/dropbear/dropbear_rsa_host_key \
    -r /etc/dropbear/dropbear_ecdsa_host_key \
    -p 127.0.0.1:2200 \
    -b /etc/dropbear/banner.txt \
    -F &
log "dropbear up on 127.0.0.1:2200"

# ---- badvpn-udpgw: lets UDP ride along inside the SSH tunnel ---------------
badvpn-udpgw --listen-addr 127.0.0.1:7300 --max-clients 128 &
log "badvpn-udpgw up on 127.0.0.1:7300"

# ---- SSH-over-HTTP-Upgrade bridge (always on) ------------------------------
python3 /opt/ws_bridge.py --listen 127.0.0.1:2222 --target 127.0.0.1:2200 &

# ---- nginx include files: start empty, filled in only if configured -------
: > /etc/nginx/relay-upstream.conf
: > /etc/nginx/relay-location.conf

# ---- Optional: OpenVPN relay to a VM ---------------------------------------
if [ -n "${OVPN_UPSTREAM_HOST:-}" ]; then
    python3 /opt/ws_bridge.py --listen 127.0.0.1:2223 \
        --target "${OVPN_UPSTREAM_HOST}:${OVPN_UPSTREAM_PORT:-1194}" &
    log "ovpn bridge up: 127.0.0.1:2223 -> ${OVPN_UPSTREAM_HOST}:${OVPN_UPSTREAM_PORT:-1194}"

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

# ---- Optional: XHTTP relay to the REALITY VM (pinned self-signed cert) ----
if [ -n "${XHTTP_UPSTREAM_HOST:-}" ]; then
    if [ -n "${XHTTP_RELAY_CERT_B64:-}" ]; then
        printf '%s' "${XHTTP_RELAY_CERT_B64}" | base64 -d > /etc/nginx/xhttp-pin.pem
    else
        log "WARNING: XHTTP_UPSTREAM_HOST set but XHTTP_RELAY_CERT_B64 is empty - relay will fail cert pinning"
        : > /etc/nginx/xhttp-pin.pem
    fi

    cat >> /etc/nginx/relay-upstream.conf <<EOF
upstream xhttp_backend { server ${XHTTP_UPSTREAM_HOST}:${XHTTP_UPSTREAM_PORT:-8443}; }
EOF
    # deploy_vm.py's setup_reality() issues the relay cert with
    # CN=vm-relay / SAN=DNS:vm-relay (not the VM's real host/IP), so that's
    # the name nginx must send as SNI and verify the cert against.
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
    log "xhttp relay: ${XHTTP_PATH:-/xhttp} -> https://${XHTTP_UPSTREAM_HOST}:${XHTTP_UPSTREAM_PORT:-8443}"
fi

# ---- /cert: basic-auth gated OpenVPN profile download ----------------------
python3 /opt/cert_server.py --listen 127.0.0.1:2224 &
log "cert_server up on 127.0.0.1:2224"

# ---- Front door -------------------------------------------------------------
nginx -t
log "starting nginx on :8080"
exec nginx -g 'daemon off;'
