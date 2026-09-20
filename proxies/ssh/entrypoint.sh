#!/bin/bash
set -e
ulimit -n 65535 || true

echo "[+] Generating SSH host keys..."
ssh-keygen -A >/dev/null 2>&1
mkdir -p /run/sshd

if [ -z "${SSH_USERS:-}" ]; then
    RANDPW=$(< /dev/urandom tr -dc 'A-Za-z0-9' | head -c16)
    SSH_USERS="saeka:${RANDPW}"
    echo "[+] SSH_USERS not set - generated one-off account saeka:${RANDPW}"
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

echo "[+] Starting BadVPN UDPGW..."
# FIX: Bound to 0.0.0.0 to prevent IPv6 localhost forwarding failures from the SSH daemon
badvpn-udpgw \
  --listen-addr 0.0.0.0:7300 \
  --max-clients 1000 \
  --max-connections-for-client 40 \
  --loglevel warning &
UDPGW_PID=$!

echo "[+] Starting native AsyncIO WS-to-TCP bridge on 0.0.0.0:8080..."
# FIX: Nginx is completely removed. Handling 8080 directly in Python is the 
# ONLY way to guarantee "101 SAEKA GCP SERVER" isn't overwritten.
cat << 'PYEOF' > /tmp/bridge.py
import asyncio

async def handle_client(reader, writer):
    try:
        # Read the initial HTTP request chunk (timeout prevents stalled sockets)
        req_data = await asyncio.wait_for(reader.read(4096), timeout=5.0)
        if not req_data:
            writer.close()
            return
        
        req_text = req_data.decode('utf-8', errors='ignore')
        
        if req_text.startswith('GET /health'):
            writer.write(b"HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n\r\nOK")
            await writer.drain()
            writer.close()
            return
            
        if req_text.startswith('GET /saeka-ssh'):
            # The exact custom 101 payload you requested
            writer.write(b"HTTP/1.1 101 SAEKA GCP SERVER\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n")
            await writer.drain()
            
            # Bridge to local SSHD
            ssh_reader, ssh_writer = await asyncio.open_connection('127.0.0.1', 22)
            
            async def forward(src, dst):
                try:
                    while True:
                        data = await src.read(65536)
                        if not data: break
                        dst.write(data)
                        await dst.drain()
                except: pass
                finally:
                    dst.close()
                    
            asyncio.create_task(forward(reader, ssh_writer))
            asyncio.create_task(forward(ssh_reader, writer))
            return

        # Default fallback
        writer.write(b"HTTP/1.1 404 Not Found\r\nContent-Type: text/plain\r\n\r\n404 Page Not Found.")
        await writer.drain()
        writer.close()
        
    except Exception:
        writer.close()

async def main():
    server = await asyncio.start_server(handle_client, '0.0.0.0', 8080)
    async with server:
        await server.serve_forever()

if __name__ == '__main__':
    asyncio.run(main())
PYEOF

echo "[+] Starting watchdog for sshd/udpgw..."
(
  while true; do
    sleep 10
    if ! kill -0 "$UDPGW_PID" 2>/dev/null; then
      echo "[watchdog] udpgw died, restarting..."
      badvpn-udpgw --listen-addr 0.0.0.0:7300 --max-clients 1000 \
        --max-connections-for-client 40 --loglevel warning &
      UDPGW_PID=$!
    fi
    if ! pgrep -x sshd > /dev/null; then
      echo "[watchdog] sshd died, restarting..."
      /usr/sbin/sshd
    fi
  done
) &

# Take over the main process with the Python bridge on port 8080
exec python3 /tmp/bridge.py
