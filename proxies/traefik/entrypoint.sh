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

# --------------------------------------------------------------------
# SSH tunnel users (SSH-over-WS at /saeka-ssh) - provisioned at container
# start from SSH_USERS, never baked into the image. Same pattern as
# ADS_MODE: set with `--set-env-vars SSH_USERS=user1:pass1,user2:pass2`
# at deploy time. Each account is forwarding-only (no shell, no TTY) -
# it's a tunnel endpoint (ssh -D ...), not a real login. If SSH_USERS is
# unset, sshd still runs but no account can authenticate.
# --------------------------------------------------------------------
mkdir -p /run/sshd
ssh-keygen -A >/dev/null 2>&1 || true
: > /etc/ssh/sshd_config.tunnel
if [ -n "${SSH_USERS:-}" ]; then
    IFS=',' read -ra PAIRS <<< "$SSH_USERS"
    for pair in "${PAIRS[@]}"; do
        user="${pair%%:*}"
        pass="${pair#*:}"
        [ -z "$user" ] && continue
        id -u "$user" >/dev/null 2>&1 || useradd -M -s /usr/sbin/nologin "$user"
        echo "${user}:${pass}" | chpasswd
        cat >> /etc/ssh/sshd_config.tunnel <<SSHDCFG

Match User ${user}
    AllowTcpForwarding yes
    X11Forwarding no
    PermitTunnel no
    GatewayPorts no
    AllowAgentForwarding no
    PermitTTY no
    ForceCommand /bin/true
SSHDCFG
        echo "[+] SSH tunnel user provisioned: $user"
    done
fi
if [ -s /etc/ssh/sshd_config.tunnel ]; then
    cat /etc/ssh/sshd_config.tunnel >> /etc/ssh/sshd_config
fi
grep -q "^PasswordAuthentication" /etc/ssh/sshd_config || echo "PasswordAuthentication yes" >> /etc/ssh/sshd_config
grep -q "^PermitRootLogin" /etc/ssh/sshd_config || echo "PermitRootLogin no" >> /etc/ssh/sshd_config

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
        engine) start engine traefik --configFile=/etc/traefik/traefik.yml ;;
        sshd)   start sshd /usr/sbin/sshd -D -e ;;
    esac
}

start xray xray run -config /etc/xray/config.json
start engine traefik --configFile=/etc/traefik/traefik.yml
start sshd /usr/sbin/sshd -D -e

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
