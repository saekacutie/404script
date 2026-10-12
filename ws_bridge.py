#!/usr/bin/env python3
"""
ws_bridge.py — local TCP <-> WebSocket bridge client.

Standard `ssh` and `openvpn` clients don't speak WebSocket. This listens
on a local TCP port and, for each connection, opens a WebSocket to your
deployed Cloud Run service and shuttles raw bytes both ways. Point your
real client at the local port instead of the remote host directly.

No dependencies beyond the standard library - implements the WebSocket
handshake (RFC 6455) and binary framing by hand, so there's nothing to
pip install on whatever machine you're running this from.

Examples:
    # SSH: server-side path is /saeka-ssh -> local sshd:22
    python3 ws_bridge.py --local-port 2222 \\
        --remote wss://yourdomain.com/saeka-ssh
    ssh -p 2222 saeka@127.0.0.1

    # OpenVPN: server-side path is /saeka-ovpn -> local OpenVPN:1194
    python3 ws_bridge.py --local-port 11940 \\
        --remote wss://yourdomain.com/saeka-ovpn
    # then in your .ovpn client config: remote 127.0.0.1 11940 tcp
"""

import argparse
import base64
import hashlib
import os
import secrets
import socket
import ssl
import struct
import sys
import threading
from urllib.parse import urlparse

GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"


def ws_handshake(sock, host, path):
    key = base64.b64encode(secrets.token_bytes(16)).decode()
    req = (
        f"GET {path} HTTP/1.1\r\n"
        f"Host: {host}\r\n"
        f"Upgrade: websocket\r\n"
        f"Connection: Upgrade\r\n"
        f"Sec-WebSocket-Key: {key}\r\n"
        f"Sec-WebSocket-Version: 13\r\n"
        f"\r\n"
    )
    sock.sendall(req.encode())

    buf = b""
    while b"\r\n\r\n" not in buf:
        chunk = sock.recv(4096)
        if not chunk:
            raise ConnectionError("Server closed connection during handshake")
        buf += chunk
    header, _, rest = buf.partition(b"\r\n\r\n")
    status_line = header.split(b"\r\n", 1)[0]
    if b"101" not in status_line:
        raise ConnectionError(f"Handshake rejected: {status_line.decode(errors='replace')}")

    expected = base64.b64encode(
        hashlib.sha1((key + GUID).encode()).digest()
    ).decode()
    if expected.encode() not in header:
        raise ConnectionError("Sec-WebSocket-Accept mismatch (not a valid WS upgrade)")
    return rest  # any bytes already read past the header


def ws_send(sock, data, opcode=0x2):
    """Send one binary (or close, 0x8) WS frame, client-masked as RFC 6455 requires."""
    fin_opcode = 0x80 | opcode
    length = len(data)
    mask = os.urandom(4)
    masked = bytes(b ^ mask[i % 4] for i, b in enumerate(data))

    if length < 126:
        header = struct.pack("!BB", fin_opcode, 0x80 | length)
    elif length < 65536:
        header = struct.pack("!BBH", fin_opcode, 0x80 | 126, length)
    else:
        header = struct.pack("!BBQ", fin_opcode, 0x80 | 127, length)
    sock.sendall(header + mask + masked)


def _recv_exact(sock, n, leftover):
    while len(leftover[0]) < n:
        chunk = sock.recv(65536)
        if not chunk:
            return None
        leftover[0] += chunk
    data, leftover[0] = leftover[0][:n], leftover[0][n:]
    return data


def ws_recv_loop(sock, on_payload, initial_buf=b""):
    """Read WS frames (server->client, unmasked) until close/EOF."""
    leftover = [initial_buf]
    while True:
        hdr = _recv_exact(sock, 2, leftover)
        if hdr is None:
            return
        b0, b1 = hdr[0], hdr[1]
        opcode = b0 & 0x0F
        length = b1 & 0x7F
        if length == 126:
            ext = _recv_exact(sock, 2, leftover)
            if ext is None:
                return
            length = struct.unpack("!H", ext)[0]
        elif length == 127:
            ext = _recv_exact(sock, 8, leftover)
            if ext is None:
                return
            length = struct.unpack("!Q", ext)[0]
        payload = _recv_exact(sock, length, leftover) if length else b""
        if payload is None:
            return
        if opcode == 0x8:  # close
            return
        if opcode in (0x1, 0x2):  # text/binary
            on_payload(payload)
        # ping/pong (0x9/0xA) and continuation frames are ignored here -
        # fine for this bridge's byte-tunnel use case.


def handle_client(client_sock, remote_url):
    parsed = urlparse(remote_url)
    use_tls = parsed.scheme == "wss"
    host = parsed.hostname
    port = parsed.port or (443 if use_tls else 80)
    path = parsed.path or "/"
    if parsed.query:
        path += "?" + parsed.query

    try:
        raw = socket.create_connection((host, port), timeout=15)
        if use_tls:
            ctx = ssl.create_default_context()
            ws_sock = ctx.wrap_socket(raw, server_hostname=host)
        else:
            ws_sock = raw
        leftover = ws_handshake(ws_sock, host, path)
    except Exception as e:
        print(f"[!] Could not connect to {remote_url}: {e}", file=sys.stderr)
        client_sock.close()
        return

    def ws_to_client(payload):
        try:
            client_sock.sendall(payload)
        except OSError:
            pass

    t = threading.Thread(target=ws_recv_loop, args=(ws_sock, ws_to_client, leftover), daemon=True)
    t.start()

    try:
        while True:
            chunk = client_sock.recv(65536)
            if not chunk:
                break
            ws_send(ws_sock, chunk)
    except OSError:
        pass
    finally:
        try:
            ws_send(ws_sock, b"", opcode=0x8)
        except OSError:
            pass
        ws_sock.close()
        client_sock.close()


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--local-port", type=int, required=True, help="Local TCP port to listen on")
    ap.add_argument("--local-host", default="127.0.0.1", help="Local bind address (default 127.0.0.1)")
    ap.add_argument("--remote", required=True, help="wss://host/path or ws://host/path")
    args = ap.parse_args()

    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind((args.local_host, args.local_port))
    srv.listen(20)
    print(f"[+] Listening on {args.local_host}:{args.local_port} -> {args.remote}")

    try:
        while True:
            client_sock, addr = srv.accept()
            threading.Thread(target=handle_client, args=(client_sock, args.remote), daemon=True).start()
    except KeyboardInterrupt:
        print("\n[+] Shutting down.")
        srv.close()


if __name__ == "__main__":
    main()
