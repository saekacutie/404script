#!/bin/bash
set -e
ulimit -n 65535 || true

echo "[+] Generating SSH host keys..."
ssh-keygen -A >/dev/null 2>&1
mkdir -p /run/sshd

# --------------------------------------------------------------------
# SSH accounts - provisioned at container start from SSH_USERS, never
# baked into the image (the working reference this is based on hardcoded
# master:boysupot at build time - fine for one person's own testing, but
# means every image built from that Dockerfile shares the same login;
# this makes it a runtime, per-deploy value instead). Format:
#   SSH_USERS="user1:pass1,user2:pass2"
# Falls back to a random one-off account if unset, so the service is
# never silently unreachable.
# --------------------------------------------------------------------
if [ -z "${SSH_USERS:-}" ]; then
    RANDPW=$(< /dev/urandom tr -dc 'A-Za-z0-9' | head -c16)
    SSH_USERS="saeka:${RANDPW}"
    echo "[+] SSH_USERS not set - generated one-off account saeka:${RANDPW} (won't persist across redeploys)"
fi
IFS=',' read -ra PAIRS <<< "$SSH_USERS"
for pair in "${PAIRS[@]}"; do
    user="${pair%%:*}"
    pass="${pair#*:}"
    [ -z "$user" ] && continue
    id -u "$user" >/dev/null 2>&1 || useradd -m -s /bin/bash "$user"
    echo "${user}:${pass}" | chpasswd
    echo "[+] SSH account ready: $user"
done

echo "[+] Starting SSH daemon..."
/usr/sbin/sshd

echo "[+] Starting BadVPN UDPGW (tuned for high-throughput gaming UDP)..."
badvpn-udpgw \
  --listen-addr 127.0.0.1:7300 \
  --max-clients 1000 \
  --max-connections-for-client 40 \
  --loglevel warning &
UDPGW_PID=$!

echo "[+] Starting WS-to-TCP bridge on 127.0.0.1:2222..."
# Deliberately NOT real RFC6455 framing: sends a canned "101 Switching
# Protocols" without validating the handshake, then relays raw bytes with
# no frame headers. This matches what SSH-tunnel client apps (HTTP
# Injector and similar) actually expect - they check for the Upgrade
# response but don't speak real WebSocket framing either. A proper
# RFC6455 bridge would NOT interoperate with those clients.
cat << 'PYEOF' > /tmp/bridge.py
import socket, threading

BUF_SIZE = 65536

def tune_socket(sock):
    sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
    try:
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 1 << 20)
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, 1 << 20)
    except OSError:
        pass

def bridge(src, dst):
    try:
        while True:
            data = src.recv(BUF_SIZE)
            if not data:
                break
            dst.sendall(data)
    except Exception:
        pass
    finally:
        src.close()
        dst.close()

def handle(client):
    try:
        tune_socket(client)
        client.recv(4096)
        client.sendall(b"HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n")
        ssh = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        tune_socket(ssh)
        ssh.connect(('127.0.0.1', 22))
        threading.Thread(target=bridge, args=(client, ssh), daemon=True).start()
        threading.Thread(target=bridge, args=(ssh, client), daemon=True).start()
    except Exception:
        client.close()

server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
server.bind(('127.0.0.1', 2222))
server.listen(200)
while True:
    client, _ = server.accept()
    threading.Thread(target=handle, args=(client,), daemon=True).start()
PYEOF

python3 /tmp/bridge.py &
BRIDGE_PID=$!

echo "[+] Starting watchdog (auto-restarts sshd/udpgw/bridge if any crash)..."
(
  while true; do
    sleep 10
    if ! kill -0 "$UDPGW_PID" 2>/dev/null; then
      echo "[watchdog] udpgw died, restarting..."
      badvpn-udpgw --listen-addr 127.0.0.1:7300 --max-clients 1000 \
        --max-connections-for-client 40 --loglevel warning &
      UDPGW_PID=$!
    fi
    if ! kill -0 "$BRIDGE_PID" 2>/dev/null; then
      echo "[watchdog] bridge died, restarting..."
      python3 /tmp/bridge.py &
      BRIDGE_PID=$!
    fi
    if ! pgrep -x sshd > /dev/null; then
      echo "[watchdog] sshd died, restarting..."
      /usr/sbin/sshd
    fi
  done
) &

echo "[+] Starting nginx..."
exec nginx -g "daemon off;"
