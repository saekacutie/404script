#!/usr/bin/env python3
"""Minimal HTTP-Upgrade bridge with a transparent TCP relay.

Accepts either CLI flags or environment variables so it can't silently
mismatch whatever the caller passes:
    --listen HOST:PORT   or  BRIDGE_LISTEN_HOST / BRIDGE_LISTEN_PORT
    --target HOST:PORT   or  BRIDGE_TARGET_HOST / BRIDGE_TARGET_PORT
"""
import argparse
import asyncio
import logging
import os
import sys

# ---------------------------------------------------------------- logging
COLORS = {
    "DEBUG": "\033[1;36m", "INFO": "\033[1;32m",
    "WARNING": "\033[1;33m", "ERROR": "\033[1;31m", "CRITICAL": "\033[1;41m",
}
RESET = "\033[0m"
USE_COLOR = sys.stderr.isatty() or os.environ.get("FORCE_COLOR") == "1"


class ColorFormatter(logging.Formatter):
    def format(self, record):
        msg = super().format(record)
        if not USE_COLOR:
            return msg
        color = COLORS.get(record.levelname, "")
        return f"{color}{msg}{RESET}"


_handler = logging.StreamHandler(sys.stderr)
_handler.setFormatter(ColorFormatter("%(asctime)s ws_bridge [%(levelname)s] %(message)s", "%H:%M:%S"))
log = logging.getLogger("ws_bridge")
log.setLevel(os.environ.get("BRIDGE_LOG_LEVEL", "INFO").upper())
log.addHandler(_handler)
log.propagate = False

HANDSHAKE_RESPONSE = b"HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n"
MAX_HEAD_BYTES = 65536


def parse_hostport(value, what):
    if not value or ":" not in value:
        raise SystemExit(f"ws_bridge: {what} must be HOST:PORT, got {value!r}")
    host, _, port = value.rpartition(":")
    try:
        port = int(port)
    except ValueError:
        raise SystemExit(f"ws_bridge: {what} port is not an integer: {value!r}")
    if not (1 <= port <= 65535):
        raise SystemExit(f"ws_bridge: {what} port out of range: {port}")
    return host, port


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


async def pipe(src, dst, tag=""):
    total = 0
    try:
        while True:
            chunk = await src.read(65536)
            if not chunk:
                break
            total += len(chunk)
            dst.write(chunk)
            await dst.drain()
    except (ConnectionResetError, BrokenPipeError, OSError) as exc:
        log.debug("pipe %s ended: %s", tag, exc)
    finally:
        try:
            dst.close()
        except OSError:
            pass
    return total


async def handle_client(reader, writer, target_host, target_port):
    peer = writer.get_extra_info("peername")
    try:
        head = await read_http_head(reader)
    except Exception as exc:
        log.warning("bad handshake from %s: %s", peer, exc)
        writer.close()
        return
    if not head:
        log.debug("empty handshake from %s (client disconnected early)", peer)
        writer.close()
        return
    try:
        up_reader, up_writer = await asyncio.open_connection(target_host, target_port)
    except OSError as exc:
        log.error("upstream %s:%s unreachable for %s: %s", target_host, target_port, peer, exc)
        writer.write(b"HTTP/1.1 502 Bad Gateway\r\n\r\n")
        await writer.drain()
        writer.close()
        return
    writer.write(HANDSHAKE_RESPONSE)
    await writer.drain()
    log.info("connected %s -> %s:%s", peer, target_host, target_port)
    down, up = await asyncio.gather(
        pipe(reader, up_writer, "down"), pipe(up_reader, writer, "up"),
    )
    log.info("closed %s (down=%dB up=%dB)", peer, down, up)


async def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--listen", default=None, help="HOST:PORT, or set BRIDGE_LISTEN_HOST/BRIDGE_LISTEN_PORT")
    parser.add_argument("--target", default=None, help="HOST:PORT, or set BRIDGE_TARGET_HOST/BRIDGE_TARGET_PORT")
    args = parser.parse_args()

    listen_spec = args.listen
    if listen_spec is None:
        lh = os.environ.get("BRIDGE_LISTEN_HOST", "0.0.0.0")
        lp = os.environ.get("BRIDGE_LISTEN_PORT")
        if not lp:
            raise SystemExit("ws_bridge: need --listen HOST:PORT or BRIDGE_LISTEN_PORT")
        listen_spec = f"{lh}:{lp}"

    target_spec = args.target
    if target_spec is None:
        th = os.environ.get("BRIDGE_TARGET_HOST")
        tp = os.environ.get("BRIDGE_TARGET_PORT")
        if not th or not tp:
            raise SystemExit("ws_bridge: need --target HOST:PORT or BRIDGE_TARGET_HOST + BRIDGE_TARGET_PORT")
        target_spec = f"{th}:{tp}"

    listen_host, listen_port = parse_hostport(listen_spec, "--listen")
    target_host, target_port = parse_hostport(target_spec, "--target")

    try:
        server = await asyncio.start_server(
            lambda r, w: handle_client(r, w, target_host, target_port),
            listen_host, listen_port,
        )
    except OSError as exc:
        log.critical("cannot bind %s:%s - %s", listen_host, listen_port, exc)
        raise SystemExit(1)

    log.info("listening on %s:%s -> relaying to %s:%s", listen_host, listen_port, target_host, target_port)
    async with server:
        await server.serve_forever()


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        pass
