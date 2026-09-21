#!/bin/bash
set -euo pipefail
ulimit -n 65535 2>/dev/null || true

GREEN='\033[1;32m'; RED='\033[1;31m'; CYAN='\033[1;36m'; YELLOW='\033[1;33m'; RESET='\033[0m'
ok()   { echo -e "  ${GREEN}[+]${RESET} $*"; }
warn() { echo -e "  ${YELLOW}[!]${RESET} $*" >&2; }
err()  { echo -e "  ${RED}[x]${RESET} $*" >&2; }

echo -e "${CYAN}== saeka reality gateway: entrypoint starting ==${RESET}"

UDPGW_PORT="${UDPGW_PORT:-7300}"
SSH_USERS="${SSH_USERS:-}"          # "user1:pass1,user2:pass2"
NGX=/etc/nginx

# ---------------------------------------------------------------- users
# No users supplied: create one random account and print it to the logs.
if [ -z "$SSH_USERS" ]; then
    gen_pass="$(python3 -c 'import secrets,string; a=string.ascii_letters+string.digits; print("".join(secrets.choice(a) for _ in range(16)))')"
    SSH_USERS="saeka:${gen_pass}"
    warn "SSH_USERS not set - generated one-off account  saeka / ${gen_pass}"
fi
export SSH_USERS   # cert_server.py reads the same list

created=0
IFS=',' read -r -a entries <<< "$SSH_USERS"
for entry in "${entries[@]}"; do
    name="${entry%%:*}"
    pass="${entry#*:}"
    if [ "$name" = "$entry" ] || [ -z "$pass" ] || ! [[ "$name" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then
        warn "skipping invalid SSH_USERS entry (expected name:password, name = a-z 0-9 _ -)"
        continue
    fi
    uid="$(id -u "$name" 2>/dev/null || true)"
    if [ -n "$uid" ] && [ "$uid" -lt 1000 ]; then
        warn "skipping '$name': system account"
        continue
    fi
    if [ -z "$uid" ]; then
        if ! useradd -m -s /bin/false "$name"; then
            err "useradd failed for '$name' - skipping this user, continuing with the rest"
            continue
        fi
    fi
    if ! printf '%s:%s\n' "$name" "$pass" | chpasswd; then
        err "chpasswd failed for '$name' - skipping this user"
        continue
    fi
    created=$((created + 1))
    ok "user ready: ${name}"
done
if [ "$created" -eq 0 ]; then
    err "no valid users - refusing to start"
    exit 1
fi

# ---------------------------------------------------- OpenVPN relay (optional)
OVPN_HOST="${OVPN_UPSTREAM_HOST:-}"
OVPN_PORT="${OVPN_UPSTREAM_PORT:-1194}"
if [ -n "$OVPN_HOST" ]; then
    if ! [[ "$OVPN_HOST" =~ ^[A-Za-z0-9.-]+$ ]]; then
        err "OVPN_UPSTREAM_HOST is not a valid IP or hostname: ${OVPN_HOST}"
        exit 1
    fi
    if ! [[ "$OVPN_PORT" =~ ^[0-9]+$ ]] || [ "$OVPN_PORT" -lt 1 ] || [ "$OVPN_PORT" -gt 65535 ]; then
        err "OVPN_UPSTREAM_PORT must be 1-65535, got: ${OVPN_PORT}"
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
        err "XHTTP_UPSTREAM_HOST is not a valid IP or hostname: ${XH_HOST}"
        exit 1
    fi
    if ! [[ "$XH_PORT" =~ ^[0-9]+$ ]] || [ "$XH_PORT" -lt 1 ] || [ "$XH_PORT" -gt 65535 ]; then
        err "XHTTP_UPSTREAM_PORT must be 1-65535, got: ${XH_PORT}"
        exit 1
    fi
    if ! [[ "$XH_PATH" =~ ^/[A-Za-z0-9._~/-]*$ ]] || [ "$XH_PATH" = "/" ]; then
        err "XHTTP_PATH must start with / and use only letters, digits and . _ ~ / -, got: ${XH_PATH}"
        exit 1
    fi
    if [ -z "$XH_CERT_B64" ]; then
        err "XHTTP_RELAY_CERT_B64 is required (the VM's self-signed cert, base64)"
        exit 1
    fi
    printf '%s' "$XH_CERT_B64" | base64 -d > "$NGX/vm-relay.pem" 2>/dev/null || true
    if ! grep -q 'BEGIN CERTIFICATE' "$NGX/vm-relay.pem"; then
        err "XHTTP_RELAY_CERT_B64 is not a valid PEM certificate"
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
    ok "relaying ${XH_PATH} -> https://${XH_HOST}:${XH_PORT} (pinned self-signed cert)"
fi

# ------------------------------------------------------------- SSH host keys
# RSA + ECDSA + ED25519 so old and new clients can all connect.
mkdir -p /etc/dropbear
[ -s /etc/dropbear/dropbear_rsa_host_key ]     || dropbearkey -t rsa -s 2048 -f /etc/dropbear/dropbear_rsa_host_key >/dev/null
[ -s /etc/dropbear/dropbear_ecdsa_host_key ]   || dropbearkey -t ecdsa -s 256 -f /etc/dropbear/dropbear_ecdsa_host_key >/dev/null
[ -s /etc/dropbear/dropbear_ed25519_host_key ] || dropbearkey -t ed25519 -f /etc/dropbear/dropbear_ed25519_host_key >/dev/null
ok "SSH host keys ready"

if [ ! -s /etc/dropbear/banner.txt ]; then
    warn "banner.txt is empty/missing - dropbear will show no banner"
fi

# --------------------------------------------------------------- services
pids=()
names=()
launch() {
    local svc_name="$1"; shift
    "$@" &
    local pid=$!
    pids+=("$pid")
    names+=("$svc_name")
    ok "started ${svc_name} (pid ${pid})"
}

cleanup() {
    trap - EXIT
    for pid in "${pids[@]:-}"; do
        kill "$pid" 2>/dev/null || true
    done
    wait 2>/dev/null || true
}
trap cleanup EXIT
trap 'exit 143' TERM INT

# UDP over SSH: clients forward to 127.0.0.1:${UDPGW_PORT} through the tunnel
launch "udpgw" badvpn-udpgw \
    --listen-addr "127.0.0.1:${UDPGW_PORT}" \
    --max-clients 1000 \
    --max-connections-for-client 500 \
    --loglevel 2

# SSH server: password login, no root, no remote forwarding
launch "dropbear" dropbear -F -E -w -k -m \
    -p 127.0.0.1:2200 \
    -r /etc/dropbear/dropbear_rsa_host_key \
    -r /etc/dropbear/dropbear_ecdsa_host_key \
    -r /etc/dropbear/dropbear_ed25519_host_key \
    -K 30 -W 65536 \
    -b /etc/dropbear/banner.txt

# HTTP-Upgrade handshake -> raw TCP, for the SSH path.
# NOTE: ws_bridge.py takes --listen/--target flags, not env vars - pass both
# explicitly here (the env vars are also set for older/patched ws_bridge.py
# builds that read them as a fallback).
BRIDGE_LISTEN_PORT=2222 BRIDGE_TARGET_HOST=127.0.0.1 BRIDGE_TARGET_PORT=2200 \
    launch "ws_bridge(ssh)" python3 /opt/ws_bridge.py \
        --listen "0.0.0.0:2222" --target "127.0.0.1:2200"

# ...and for the OpenVPN path, only when a VM address was given
if [ -n "$OVPN_HOST" ]; then
    ok "relaying /saeka-ovpn -> ${OVPN_HOST}:${OVPN_PORT}"
    BRIDGE_LISTEN_PORT=2223 BRIDGE_TARGET_HOST="$OVPN_HOST" BRIDGE_TARGET_PORT="$OVPN_PORT" \
        launch "ws_bridge(ovpn)" python3 /opt/ws_bridge.py \
            --listen "0.0.0.0:2223" --target "${OVPN_HOST}:${OVPN_PORT}"
fi

# /cert: answers 503 unless both OVPN_PROFILE_B64 and users exist
launch "cert_server" python3 /opt/cert_server.py

launch "nginx" nginx -g 'daemon off;'

echo ""
echo -e "  ${CYAN}------------------------------------------------------------${RESET}"
echo -e "  ${GREEN}all services launched:${RESET} ${names[*]}"
echo -e "  ${CYAN}udpgw${RESET}        127.0.0.1:${UDPGW_PORT}"
echo -e "  ${CYAN}dropbear${RESET}     127.0.0.1:2200  (via /saeka-ssh)"
echo -e "  ${CYAN}ws_bridge ssh${RESET} 0.0.0.0:2222 -> 127.0.0.1:2200"
[ -n "$OVPN_HOST" ] && echo -e "  ${CYAN}ws_bridge ovpn${RESET} 0.0.0.0:2223 -> ${OVPN_HOST}:${OVPN_PORT}"
[ -n "$XH_HOST" ] && echo -e "  ${CYAN}xhttp relay${RESET}  ${XH_PATH} -> ${XH_HOST}:${XH_PORT}"
echo -e "  ${CYAN}cert_server${RESET}  127.0.0.1:${CERT_PORT:-2224}  (via /cert)"
echo -e "  ${CYAN}nginx${RESET}        0.0.0.0:8080"
echo -e "  ${CYAN}------------------------------------------------------------${RESET}"
echo ""

# If any service dies, exit so Cloud Run starts a fresh instance. Report
# which one, since that's the single most useful line for debugging a
# crash-loop and the old script never printed it.
wait -n || true
for i in "${!pids[@]}"; do
    if ! kill -0 "${pids[$i]}" 2>/dev/null; then
        err "service '${names[$i]}' (pid ${pids[$i]}) exited - shutting down container"
    fi
done
exit 1
