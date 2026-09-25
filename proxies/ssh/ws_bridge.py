#!/usr/bin/env python3
"""HTTP-Upgrade handshake -> raw TCP bridge.

Clients (HTTP Injector / NPV Tunnel style) send "GET <path> HTTP/1.1" with
"Upgrade: websocket". We answer 101 Switching Protocols, then pipe raw bytes
to the target. Bytes the client sends right after its headers are kept.

Usage:
    ws_bridge.py LISTEN_PORT TARGET_HOST TARGET_PORT [LABEL]

(LISTEN_PORT always binds 127.0.0.1. LABEL is only used in log lines.)
"""
import asyncio
import base64
import hashlib
import socket
import sys

LISTEN_HOST = "127.0.0.1"
WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
BUF = 65536
HEADER_TIMEOUT = 30
CONNECT_TIMEOUT = 10

HTTP_OK = (b"HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n"
           b"Content-Length: 2\r\nConnection: close\r\n\r\nOK")
HTTP_BAD_GATEWAY = (b"HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\n"
                    b"Connection: close\r\n\r\n")


def log(label, msg):
    prefix = f"[bridge:{label}]" if label else "[bridge]"
    print(f"{prefix} {msg}", file=sys.stderr, flush=True)


def tune(writer):
    sock = writer.get_extra_info("socket")
    if sock is not None:
        try:
            sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
            sock.setsockopt(socket.SOL_SOCKET, socket.SO_KEEPALIVE, 1)
        except OSError:
            pass


def parse_headers(head):
    headers = {}
    for line in head.decode("latin-1").split("\r\n")[1:]:
        if ":" in line:
            key, value = line.split(":", 1)
            headers[key.strip().lower()] = value.strip()
    return headers


def switching_response(key):
    out = ("HTTP/1.1 101 Switching Protocols\r\n"
           "Upgrade: websocket\r\n"
           "Connection: Upgrade\r\n")
    if key:
        digest = hashlib.sha1((key + WS_GUID).encode()).digest()
        out += "Sec-WebSocket-Accept: %s\r\n" % base64.b64encode(digest).decode()
    return (out + "\r\n").encode()


async def pipe(reader, writer):
    try:
        while True:
            data = await reader.read(BUF)
            if not data:
                break
            writer.write(data)
            await writer.drain()
    except Exception:
        pass
    finally:
        try:
            writer.close()
        except Exception:
            pass


async def handle(creader, cwriter, target_host, target_port, label):
    uwriter = None
    try:
        tune(cwriter)
        try:
            head = await asyncio.wait_for(
                creader.readuntil(b"\r\n\r\n"), timeout=HEADER_TIMEOUT)
        except (asyncio.TimeoutError, asyncio.IncompleteReadError,
                asyncio.LimitOverrunError):
            return

        headers = parse_headers(head)
        if "upgrade" not in headers:
            cwriter.write(HTTP_OK)
            await cwriter.drain()
            return

        try:
            ureader, uwriter = await asyncio.wait_for(
                asyncio.open_connection(target_host, target_port),
                timeout=CONNECT_TIMEOUT)
        except (OSError, asyncio.TimeoutError) as exc:
            log(label, "upstream %s:%s unreachable: %r" % (target_host, target_port, exc))
            cwriter.write(HTTP_BAD_GATEWAY)
            await cwriter.drain()
            return
        tune(uwriter)

        cwriter.write(switching_response(headers.get("sec-websocket-key", "")))
        await cwriter.drain()

        # This single upgraded TCP connection is a raw, full-duplex byte
        # pipe to the target (dropbear or the OpenVPN VM) - both directions
        # pumped concurrently, so it's fully transparent to whatever the
        # client tunnels over it (including UDPGW's UDP-in-TCP framing,
        # which just needs an ordinary reliable byte stream).
        tasks = [
            asyncio.create_task(pipe(creader, uwriter)),
            asyncio.create_task(pipe(ureader, cwriter)),
        ]
        _, pending = await asyncio.wait(tasks, return_when=asyncio.FIRST_COMPLETED)
        for task in pending:
            task.cancel()
        await asyncio.gather(*pending, return_exceptions=True)
    except (ConnectionError, OSError):
        pass
    finally:
        for w in (cwriter, uwriter):
            if w is not None:
                try:
                    w.close()
                except Exception:
                    pass


async def main():
    if len(sys.argv) < 4:
        print(__doc__, file=sys.stderr)
        raise SystemExit(2)

    listen_port = int(sys.argv[1])
    target_host = sys.argv[2]
    target_port = int(sys.argv[3])
    label = sys.argv[4] if len(sys.argv) > 4 else ""

    if not target_host or not target_port:
        log(label, "no target host/port given - refusing to start")
        raise SystemExit(1)

    async def _handle(creader, cwriter):
        await handle(creader, cwriter, target_host, target_port, label)

    server = await asyncio.start_server(
        _handle, LISTEN_HOST, listen_port, limit=BUF, backlog=1024)
    log(label, "listening on %s:%s -> %s:%s" % (LISTEN_HOST, listen_port, target_host, target_port))
    async with server:
        await server.serve_forever()


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        pass
