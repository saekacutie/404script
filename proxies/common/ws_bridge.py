#!/usr/bin/env python3
"""HTTP Upgrade to raw TCP bridge used by SSH/OpenVPN relays.

This is intentionally not RFC6455 WebSocket framing.  HTTP Injector/NPV style
clients expect a 101 response followed by an unmodified byte stream.
"""
import argparse
import asyncio
import base64
import hashlib
import logging
import os

logging.basicConfig(level=logging.INFO, format="%(asctime)s ws_bridge %(message)s")
log = logging.getLogger("ws_bridge")

GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
MAX_HEAD = 65536
BUF = 65536


def tune(writer):
    sock = writer.get_extra_info("socket")
    if sock is not None:
        try:
            sock.setsockopt(6, 1, 1)  # IPPROTO_TCP/TCP_NODELAY
            sock.setsockopt(1, 9, 1)  # SOL_SOCKET/SO_KEEPALIVE
        except OSError:
            pass


def response(key):
    out = b"HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
    if key:
        digest = hashlib.sha1((key + GUID).encode("ascii")).digest()
        out += b"Sec-WebSocket-Accept: " + base64.b64encode(digest) + b"\r\n"
    return out + b"\r\n"


async def read_head(reader):
    data = bytearray()
    while b"\r\n\r\n" not in data:
        chunk = await asyncio.wait_for(reader.read(4096), timeout=30)
        if not chunk:
            break
        data.extend(chunk)
        if len(data) > MAX_HEAD:
            raise ConnectionError("request headers too large")
    return bytes(data)


def headers(head):
    result = {}
    for line in head.decode("latin-1").split("\r\n"):
        if ":" in line:
            key, value = line.split(":", 1)
            result[key.strip().lower()] = value.strip()
    return result


async def pipe(source, target):
    try:
        while True:
            data = await source.read(BUF)
            if not data:
                return
            target.write(data)
            await target.drain()
    except (asyncio.CancelledError, ConnectionError, OSError):
        return
    finally:
        try:
            target.close()
        except Exception:
            pass


async def handle(client, target_host, target_port):
    peer = client.get_extra_info("peername")
    try:
        tune(client)
        head = await read_head(client)
        if not head:
            client.close()
            return
        hdrs = headers(head)
        if "upgrade" not in hdrs:
            client.write(b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nOK")
            await client.drain()
            client.close()
            return
        upstream_reader, upstream = await asyncio.wait_for(
            asyncio.open_connection(target_host, target_port), timeout=10
        )
        tune(upstream)
        client.write(response(hdrs.get("sec-websocket-key", "")))
        await client.drain()

        tasks = [
            asyncio.create_task(pipe(client, upstream)),
            asyncio.create_task(pipe(upstream_reader, client)),
        ]
        _, pending = await asyncio.wait(tasks, return_when=asyncio.FIRST_COMPLETED)
        for task in pending:
            task.cancel()
        await asyncio.gather(*pending, return_exceptions=True)
    except (asyncio.TimeoutError, ConnectionError, OSError) as exc:
        log.warning("%s: %s", peer, exc)
    finally:
        try:
            client.close()
        except Exception:
            pass


async def serve(listen_host, listen_port, target_host, target_port):
    server = await asyncio.start_server(
        lambda r, w: handle(w, target_host, target_port),
        listen_host, listen_port, limit=BUF, backlog=1024,
    )
    log.info("listening on %s:%s -> %s:%s", listen_host, listen_port, target_host, target_port)
    async with server:
        await server.serve_forever()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("listen", nargs="?")
    parser.add_argument("target_host", nargs="?")
    parser.add_argument("target_port", nargs="?")
    parser.add_argument("name", nargs="?", default="bridge")
    parser.add_argument("--listen", dest="listen_opt")
    parser.add_argument("--target", dest="target_opt")
    args = parser.parse_args()

    listen = args.listen_opt or args.listen or os.environ.get("BRIDGE_LISTEN", "127.0.0.1:2222")
    target = args.target_opt or (
        f"{args.target_host}:{args.target_port}" if args.target_host and args.target_port else
        f"{os.environ.get('BRIDGE_TARGET_HOST', '127.0.0.1')}:{os.environ.get('BRIDGE_TARGET_PORT', '2200')}"
    )
    listen_host, listen_port = listen.rsplit(":", 1)
    target_host, target_port = target.rsplit(":", 1)
    asyncio.run(serve(listen_host, int(listen_port), target_host, int(target_port)))


if __name__ == "__main__":
    main()
