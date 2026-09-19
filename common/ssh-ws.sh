#!/bin/bash
# SSH-over-WebSocket backend, sourced by every proxies/*/entrypoint.sh.
#
#   client --WS /saeka-ssh--> [proxy engine :8080] --> xray dokodemo (127.0.0.1:10016)
#          --> dropbear (127.0.0.1:2222)
#
# Env (all optional):
#   SSH_ENABLE=1        set to 0 to turn the feature off
#   SSH_USER=saeka      SSH_PASS=saeka
#
# The account has shell /bin/false: TCP forwarding (-D / -L / ProxyCommand)
# works, interactive shells and remote commands do not.

SSH_ENABLE="${SSH_ENABLE:-1}"
SSH_USER="${SSH_USER:-saeka}"
SSH_PASS="${SSH_PASS:-saeka}"
SSH_LOCAL_PORT=2222
SSH_WS_PORT=10016
SSH_WS_PATH=/saeka-ssh
SSH_WS_CFG="${SSH_WS_CFG:-/etc/xray/ssh-ws.json}"
SSHD_PID=""
SSHWS_PID=""

_ssh_ws_user() {
    if ! id "$SSH_USER" >/dev/null 2>&1; then
        if command -v useradd >/dev/null 2>&1; then
            useradd -M -s /bin/false "$SSH_USER"
        else
            adduser -D -H -s /bin/false "$SSH_USER"
        fi
    fi
    # dropbear refuses users whose shell is not listed in /etc/shells
    grep -qx /bin/false /etc/shells 2>/dev/null || echo /bin/false >> /etc/shells
    printf '%s:%s\n' "$SSH_USER" "$SSH_PASS" | chpasswd -c sha512 2>/dev/null \
        || printf '%s:%s\n' "$SSH_USER" "$SSH_PASS" | chpasswd
}

_ssh_ws_config() {
    mkdir -p "$(dirname "$SSH_WS_CFG")"
    cat > "$SSH_WS_CFG" <<XRAYCFG
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "tag": "ssh-ws",
      "listen": "127.0.0.1",
      "port": ${SSH_WS_PORT},
      "protocol": "dokodemo-door",
      "settings": { "address": "127.0.0.1", "port": ${SSH_LOCAL_PORT}, "network": "tcp" },
      "streamSettings": { "network": "ws", "wsSettings": { "path": "${SSH_WS_PATH}" } }
    }
  ],
  "outbounds": [ { "protocol": "freedom", "tag": "direct" } ]
}
XRAYCFG
}

_ssh_ws_launch_sshd() {
    # -F foreground  -E log to stderr  -R auto host keys  -w no root
    # -k no remote (-R) forwarding     -K 30 keepalive so idle tunnels survive
    dropbear -F -E -R -w -k -K 30 -p "127.0.0.1:${SSH_LOCAL_PORT}" &
    SSHD_PID=$!
}

_ssh_ws_launch_bridge() {
    xray run -config "$SSH_WS_CFG" &
    SSHWS_PID=$!
}

ssh_ws_start() {
    if [ "$SSH_ENABLE" != "1" ]; then
        echo "[+] SSH-WS disabled (SSH_ENABLE=$SSH_ENABLE)"
        return 0
    fi
    if ! command -v dropbear >/dev/null 2>&1; then
        echo "[!] dropbear not installed - SSH-WS skipped (see common/ssh-install.sh)"
        SSH_ENABLE=0
        return 0
    fi
    echo "[+] Starting SSH-WS (ws ${SSH_WS_PATH} -> dropbear, user: ${SSH_USER})..."
    mkdir -p /etc/dropbear
    _ssh_ws_user || echo "[!] could not set password for ${SSH_USER}"
    _ssh_ws_config
    _ssh_ws_launch_sshd
    _ssh_ws_launch_bridge
}

ssh_ws_watch() {
    [ "$SSH_ENABLE" = "1" ] || return 0
    if ! kill -0 "$SSHD_PID" 2>/dev/null; then
        echo "[watchdog] dropbear died, restarting..."
        _ssh_ws_launch_sshd
    fi
    if ! kill -0 "$SSHWS_PID" 2>/dev/null; then
        echo "[watchdog] ssh-ws bridge died, restarting..."
        _ssh_ws_launch_bridge
    fi
    return 0
}

ssh_ws_pids() { echo "$SSHD_PID $SSHWS_PID"; }
