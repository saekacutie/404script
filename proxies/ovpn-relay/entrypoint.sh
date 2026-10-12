#!/bin/bash
set -e
ulimit -n 65535 || true

if [ -z "${OVPN_UPSTREAM_HOST:-}" ]; then
    echo "[!] OVPN_UPSTREAM_HOST is not set - this relay has nothing to forward to."
    echo "[!] Set it to the static IP of the VM running OpenVPN (see deploy_vm.py)."
    echo "[!] Starting anyway so the service doesn't crash-loop, but /saeka-ovpn will fail every connection."
fi
OVPN_UPSTREAM_HOST="${OVPN_UPSTREAM_HOST:-0.0.0.0}"
OVPN_UPSTREAM_PORT="${OVPN_UPSTREAM_PORT:-1194}"
echo "[+] Relaying /saeka-ovpn -> ${OVPN_UPSTREAM_HOST}:${OVPN_UPSTREAM_PORT}"

# Same fake-handshake, raw-passthrough style as the SSH gateway, for the
# same reason: whatever client wraps your OpenVPN client's TCP connection
# needs to speak this exact pattern, not real RFC6455 WebSocket framing.
cat > /tmp/bridge.py << PYEOF
import socket, threading

UPSTREAM_HOST = "${OVPN_UPSTREAM_HOST}"
UPSTREAM_PORT = ${OVPN_UPSTREAM_PORT}
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
        upstream = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        tune_socket(upstream)
        upstream.settimeout(10)
        upstream.connect((UPSTREAM_HOST, UPSTREAM_PORT))
        upstream.settimeout(None)
        threading.Thread(target=bridge, args=(client, upstream), daemon=True).start()
        threading.Thread(target=bridge, args=(upstream, client), daemon=True).start()
    except Exception as e:
        print(f"[bridge] upstream connect failed: {e}")
        client.close()

server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
server.bind(('127.0.0.1', 2223))
server.listen(200)
while True:
    client, _ = server.accept()
    threading.Thread(target=handle, args=(client,), daemon=True).start()
PYEOF

python3 /tmp/bridge.py &
BRIDGE_PID=$!

(
  while true; do
    sleep 10
    if ! kill -0 "$BRIDGE_PID" 2>/dev/null; then
      echo "[watchdog] bridge died, restarting..."
      python3 /tmp/bridge.py &
      BRIDGE_PID=$!
    fi
  done
) &

echo "[+] Starting nginx..."
exec nginx -g "daemon off;"
