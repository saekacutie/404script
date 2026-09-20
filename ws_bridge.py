#!/usr/bin/env python3
"""HTTP-Upgrade handshake -> raw TCP bridge.

Clients (HTTP Injector / NPV Tunnel style) send "GET <path> HTTP/1.1" with
"Upgrade: websocket". We answer 101 Switching Protocols, then pipe raw bytes
to the target. Bytes the client sends right after its headers are kept.

Environment:
  BRIDGE_LISTEN_PORT  port to listen on (127.0.0.1)
  BRIDGE_TARGET_HOST  upstream host
  BRIDGE_TARGET_PORT  upstream port
"""
import asyncio
import base64
import hashlib
import os
import socket
import sys

LISTEN_HOST = "127.0.0.1"
LISTEN_PORT = int(os.environ["BRIDGE_LISTEN_PORT"])
TARGET_HOST = os.environ["BRIDGE_TARGET_HOST"]
TARGET_PORT = int(os.environ["BRIDGE_TARGET_PORT"])

WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
BUF = 65536
HEADER_TIMEOUT = 30
CONNECT_TIMEOUT = 10

HTTP_OK = (b"HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n"
           b"Content-Length: 2\r\nConnection: close\r\n\r\nOK")
HTTP_BAD_GATEWAY = (b"HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\n"
                    b"Connection: close\r\n\r\n")


def log(msg):
    print("[bridge] " + msg, file=sys.stderr, flush=True)


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


async def handle(creader, cwriter):
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
                asyncio.open_connection(TARGET_HOST, TARGET_PORT),
                timeout=CONNECT_TIMEOUT)
        except (OSError, asyncio.TimeoutError) as exc:
            log("upstream %s:%s unreachable: %r" % (TARGET_HOST, TARGET_PORT, exc))
            cwriter.write(HTTP_BAD_GATEWAY)
            await cwriter.drain()
            return
        tune(uwriter)

        cwriter.write(switching_response(headers.get("sec-websocket-key", "")))
        await cwriter.drain()

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
    server = await asyncio.start_server(
        handle, LISTEN_HOST, LISTEN_PORT, limit=BUF, backlog=1024)
    log("listening on %s:%s -> %s:%s" % (LISTEN_HOST, LISTEN_PORT, TARGET_HOST, TARGET_PORT))
    async with server:
        await server.serve_forever()


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        pass
