#!/usr/bin/env python3
"""Minimal HTTP-Upgrade bridge with a transparent TCP relay."""
import argparse
import asyncio
import logging

logging.basicConfig(level=logging.INFO, format="%(asctime)s ws_bridge %(message)s")
log = logging.getLogger("ws_bridge")
HANDSHAKE_RESPONSE = b"HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n"
MAX_HEAD_BYTES = 65536

async def read_http_head(reader):
    data = b""
    while b"\r\n\r\n" not in data:
        chunk = await reader.read(4096)
        if not chunk:
            break
        data += chunk
        if len(data) > MAX_HEAD_BYTES:
            raise ConnectionError("request headers too large")
    return data

async def pipe(src, dst):
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

async def handle_client(reader, writer, target_host, target_port):
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
    except OSError:
        writer.write(b"HTTP/1.1 502 Bad Gateway\r\n\r\n")
        await writer.drain()
        writer.close()
        return
    writer.write(HANDSHAKE_RESPONSE)
    await writer.drain()
    await asyncio.gather(pipe(reader, up_writer), pipe(up_reader, writer))

async def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--listen", required=True)
    parser.add_argument("--target", required=True)
    args = parser.parse_args()
    listen_host, listen_port = args.listen.rsplit(":", 1)
    target_host, target_port = args.target.rsplit(":", 1)
    server = await asyncio.start_server(lambda r, w: handle_client(r, w, target_host, int(target_port)), listen_host, int(listen_port))
    async with server:
        await server.serve_forever()

if __name__ == "__main__":
    asyncio.run(main())
