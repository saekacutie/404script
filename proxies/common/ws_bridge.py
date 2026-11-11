#!/usr/bin/env python3
"""HTTP-Upgrade handshake -> raw TCP bridge (SSH / OpenVPN / REALITY relays).

HTTP Injector / NPV Tunnel style clients send "GET <path> HTTP/1.1" with
"Upgrade: websocket" and expect "101 Switching Protocols" followed by an
unmodified byte stream (this is deliberately not RFC6455 framing). Bytes the
client sends right behind its headers are kept and forwarded.

Usage (both forms work):
    ws_bridge.py LISTEN_PORT TARGET_HOST TARGET_PORT [LABEL]
    ws_bridge.py --listen [HOST:]PORT --target HOST:PORT [--label NAME]

Environment fallback: BRIDGE_LISTEN, BRIDGE_TARGET_HOST, BRIDGE_TARGET_PORT.
A plain (non-upgrade) request, such as a health check, gets "200 OK".
"""
import argparse
import asyncio
import base64
import hashlib
import os
import socket
import sys

WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
BUF = 65536
MAX_HEAD = 65536
HEADER_TIMEOUT = 30
CONNECT_TIMEOUT = 8
CONNECT_TRIES = 3

HTTP_OK = (b"HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n"
           b"Content-Length: 2\r\nConnection: close\r\n\r\nOK")
HTTP_BAD_GATEWAY = (b"HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\n"
                    b"Connection: close\r\n\r\n")
HTTP_BAD_REQUEST = (b"HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\n"
                    b"Connection: close\r\n\r\n")


def log(label, msg):
    print("[bridge:%s] %s" % (label, msg), file=sys.stderr, flush=True)


def tune(writer):
    """Low latency + dead-peer detection (keeps idle tunnels alive end to end)."""
    sock = writer.get_extra_info("socket")
    if sock is None:
        return
    try:
        sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_KEEPALIVE, 1)
        for name, value in (("TCP_KEEPIDLE", 30), ("TCP_KEEPINTVL", 10), ("TCP_KEEPCNT", 4)):
            opt = getattr(socket, name, None)
            if opt is not None:
                sock.setsockopt(socket.IPPROTO_TCP, opt, value)
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
        digest = hashlib.sha1((key + WS_GUID).encode("ascii", "ignore")).digest()
        out += "Sec-WebSocket-Accept: %s\r\n" % base64.b64encode(digest).decode()
    return (out + "\r\n").encode()


async def finish(writer, payload=b""):
    try:
        if payload:
            writer.write(payload)
            await writer.drain()
        writer.close()
        await writer.wait_closed()
    except (AttributeError, ConnectionError, OSError):
        pass


async def pipe(reader, writer):
    """Copy reader -> writer until EOF or error."""
    try:
        while True:
            data = await reader.read(BUF)
            if not data:
                break
            writer.write(data)
            await writer.drain()
    except (ConnectionError, OSError):
        pass


async def open_upstream(host, port, label):
    last = None
    for attempt in range(CONNECT_TRIES):
        try:
            return await asyncio.wait_for(asyncio.open_connection(host, port), timeout=CONNECT_TIMEOUT)
        except (OSError, asyncio.TimeoutError) as exc:
            last = exc
            await asyncio.sleep(0.25 * (attempt + 1))
    log(label, "upstream %s:%s unreachable: %r" % (host, port, last))
    return None


async def handle(creader, cwriter, target_host, target_port, label):
    uwriter = None
    try:
        tune(cwriter)
        try:
            head = await asyncio.wait_for(creader.readuntil(b"\r\n\r\n"), timeout=HEADER_TIMEOUT)
        except asyncio.LimitOverrunError:
            return await finish(cwriter, HTTP_BAD_REQUEST)
        except (asyncio.TimeoutError, asyncio.IncompleteReadError, ConnectionError, OSError):
            return await finish(cwriter)
        if len(head) > MAX_HEAD:
            return await finish(cwriter, HTTP_BAD_REQUEST)

        headers = parse_headers(head)
        if "upgrade" not in headers:
            return await finish(cwriter, HTTP_OK)

        upstream = await open_upstream(target_host, target_port, label)
        if upstream is None:
            return await finish(cwriter, HTTP_BAD_GATEWAY)
        ureader, uwriter = upstream
        tune(uwriter)

        cwriter.write(switching_response(headers.get("sec-websocket-key", "")))
        await cwriter.drain()

        # Full-duplex raw pipe. When either side ends, the tunnel is over.
        tasks = [asyncio.ensure_future(pipe(creader, uwriter)),
                 asyncio.ensure_future(pipe(ureader, cwriter))]
        try:
            await asyncio.wait(tasks, return_when=asyncio.FIRST_COMPLETED)
        finally:
            for task in tasks:
                task.cancel()
            await asyncio.gather(*tasks, return_exceptions=True)
    except (ConnectionError, OSError):
        pass
    except Exception as exc:  # never let one bad client take the listener down
        log(label, "unexpected error: %r" % (exc,))
    finally:
        for w in (cwriter, uwriter):
            if w is not None:
                try:
                    w.close()
                except Exception:
                    pass


def split_hostport(value, default_host):
    value = str(value).strip()
    if ":" in value:
        host, _, port = value.rpartition(":")
        return (host.strip("[]") or default_host), int(port)
    return default_host, int(value)


async def serve(listen_host, listen_port, target_host, target_port, label, ready=None):
    async def _handle(creader, cwriter):
        await handle(creader, cwriter, target_host, target_port, label)

    server = await asyncio.start_server(_handle, listen_host, listen_port, limit=BUF, backlog=2048)
    log(label, "listening on %s:%s -> %s:%s" % (listen_host, listen_port, target_host, target_port))
    if ready is not None:
        ready.set()
    async with server:
        await server.serve_forever()


def parse_args(argv=None):
    parser = argparse.ArgumentParser(description="HTTP-Upgrade -> raw TCP bridge")
    parser.add_argument("listen", nargs="?")
    parser.add_argument("target_host", nargs="?")
    parser.add_argument("target_port", nargs="?")
    parser.add_argument("name", nargs="?", default="")
    parser.add_argument("--listen", dest="listen_opt")
    parser.add_argument("--target", dest="target_opt")
    parser.add_argument("--label", dest="label_opt")
    args = parser.parse_args(argv)

    listen = args.listen_opt or args.listen or os.environ.get("BRIDGE_LISTEN") or \
        os.environ.get("BRIDGE_LISTEN_PORT", "")
    if args.target_opt:
        target = args.target_opt
    elif args.target_host and args.target_port:
        target = "%s:%s" % (args.target_host, args.target_port)
    else:
        target = "%s:%s" % (os.environ.get("BRIDGE_TARGET_HOST", ""), os.environ.get("BRIDGE_TARGET_PORT", ""))
    label = args.label_opt or args.name or "bridge"
    if not listen:
        parser.error("no listen port given")
    try:
        listen_host, listen_port = split_hostport(listen, "127.0.0.1")
        target_host, target_port = split_hostport(target, "")
    except ValueError:
        parser.error("listen/target must look like [HOST:]PORT / HOST:PORT")
    if not target_host or not target_port:
        parser.error("no target host/port given - refusing to start")
    return listen_host, listen_port, target_host, target_port, label


def main():
    listen_host, listen_port, target_host, target_port, label = parse_args()
    try:
        asyncio.run(serve(listen_host, listen_port, target_host, target_port, label))
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
