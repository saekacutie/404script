#!/usr/bin/env python3
"""Minimal HTTP-Upgrade bridge.

Speaks just enough HTTP to satisfy tunneling clients (HTTP Injector, NPV
Tunnel, and similar) that send one HTTP request with an Upgrade header and
then expect the raw byte stream to flow straight through to a TCP backend.
This is deliberately NOT RFC6455 WebSocket framing -- it's a bare handshake
followed by a transparent relay, which is what those clients expect.

Two instances of this script run in the container: one bridges
127.0.0.1:2222 -> 127.0.0.1:2200 (Dropbear, for /saeka-ssh) and, only when
OVPN_UPSTREAM_HOST is set, a second bridges 127.0.0.1:2223 -> the OpenVPN
VM (for /saeka-ovpn).
"""
import argparse
import asyncio
import logging

logging.basicConfig(level=logging.INFO, format="%(asctime)s ws_bridge %(message)s")
log = logging.getLogger("ws_bridge")

HANDSHAKE_RESPONSE = (
    b"HTTP/1.1 101 Switching Protocols\r\n"
    b"Upgrade: websocket\r\n"
    b"Connection: Upgrade\r\n"
    b"\r\n"
)

MAX_HEAD_BYTES = 65536


async def read_http_head(reader: asyncio.StreamReader) -> bytes:
    """Read up to (and including) the blank line ending the HTTP headers."""
    data = b""
    while b"\r\n\r\n" not in data:
        chunk = await reader.read(4096)
        if not chunk:
            break
        data += chunk
        if len(data) > MAX_HEAD_BYTES:
            raise ConnectionError("request headers too large")
    return data


async def pipe(src: asyncio.StreamReader, dst: asyncio.StreamWriter) -> None:
    try:
        while True:
            chunk = await src.read(65536)
            if not chunk:
                break
            dst.write(chunk)
            await dst.drain()
    except (ConnectionResetError, BrokenPipeError, OSError):
        pass
    finally:
        try:
            dst.close()
        except OSError:
            pass


async def handle_client(reader, writer, target_host: str, target_port: int) -> None:
    peer = writer.get_extra_info("peername")
    try:
        head = await read_http_head(reader)
    except Exception as exc:
        log.warning("bad handshake from %s: %s", peer, exc)
        writer.close()
        return
    if not head:
        writer.close()
        return

    try:
        up_reader, up_writer = await asyncio.open_connection(target_host, target_port)
    except OSError as exc:
        log.warning("upstream %s:%s unreachable: %s", target_host, target_port, exc)
        writer.write(b"HTTP/1.1 502 Bad Gateway\r\n\r\n")
        await writer.drain()
        writer.close()
        return

    writer.write(HANDSHAKE_RESPONSE)
    await writer.drain()
    log.info("relaying %s -> %s:%s", peer, target_host, target_port)

    await asyncio.gather(
        pipe(reader, up_writer),
        pipe(up_reader, writer),
    )


async def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--listen", required=True, help="host:port to listen on")
    parser.add_argument("--target", required=True, help="host:port to relay to")
    args = parser.parse_args()

    listen_host, listen_port = args.listen.rsplit(":", 1)
    target_host, target_port = args.target.rsplit(":", 1)

    server = await asyncio.start_server(
        lambda r, w: handle_client(r, w, target_host, int(target_port)),
        listen_host,
        int(listen_port),
    )
    log.info("listening on %s -> %s", args.listen, args.target)
    async with server:
        await server.serve_forever()


if __name__ == "__main__":
    asyncio.run(main())
