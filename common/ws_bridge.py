#!/usr/bin/env python3
import sys
import socket
import asyncio
import logging
import websockets

logging.basicConfig(level=logging.INFO, format="[ws_bridge] %(asctime)s - %(levelname)s - %(message)s")

LISTEN_PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 2223
TARGET_HOST = sys.argv[2] if len(sys.argv) > 2 else ""
TARGET_PORT = int(sys.argv[3]) if len(sys.argv) > 3 else 1194

async def handle_client(websocket):
    if not TARGET_HOST:
        logging.error("Target host not configured!")
        await websocket.close(1011, "Upstream host not configured")
        return

    client_addr = websocket.remote_address
    logging.info(f"New client connected: {client_addr}")

    try:
        reader, writer = await asyncio.open_connection(TARGET_HOST, TARGET_PORT)
        sock = writer.get_extra_info('socket')
        if sock:
            sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
            sock.setsockopt(socket.SOL_SOCKET, socket.SO_KEEPALIVE, 1)
    except Exception as e:
        logging.error(f"Failed to connect to upstream {TARGET_HOST}:{TARGET_PORT} - {e}")
        await websocket.close(1011, "Upstream connection failed")
        return

    async def ws_to_tcp():
        try:
            async for message in websocket:
                if isinstance(message, str):
                    message = message.encode('utf-8')
                writer.write(message)
                await writer.drain()
        except (websockets.exceptions.ConnectionClosed, ConnectionResetError, BrokenPipeError):
            pass
        except Exception as e:
            logging.debug(f"ws_to_tcp error: {e}")
        finally:
            writer.close()
            try:
                await writer.wait_closed()
            except Exception:
                pass

    async def tcp_to_ws():
        try:
            while True:
                data = await reader.read(65536)
                if not data:
                    break
                await websocket.send(data)
        except (websockets.exceptions.ConnectionClosed, ConnectionResetError, BrokenPipeError):
            pass
        except Exception as e:
            logging.debug(f"tcp_to_ws error: {e}")
        finally:
            try:
                await websocket.close()
            except Exception:
                pass

    try:
        await asyncio.gather(ws_to_tcp(), tcp_to_ws(), return_exceptions=True)
    finally:
        logging.info(f"Client disconnected: {client_addr}")

async def main():
    logging.info(f"Starting WS bridge on 0.0.0.0:{LISTEN_PORT} -> {TARGET_HOST}:{TARGET_PORT}")
    async with websockets.serve(
        handle_client,
        "0.0.0.0",
        LISTEN_PORT,
        max_size=None,
        ping_interval=20,
        ping_timeout=20,
        max_queue=1024
    ):
        await asyncio.Future()

if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        pass
