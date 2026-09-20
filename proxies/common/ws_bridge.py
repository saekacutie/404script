#!/usr/bin/env python3
"""Fake-WebSocket handshake, then raw byte relay.

usage: ws_bridge.py LISTEN_PORT UPSTREAM_HOST UPSTREAM_PORT NAME

Deliberately NOT real RFC6455: it answers with a canned "101 Switching
Protocols" without validating the request, then relays raw bytes with no
frame headers. That is what HTTP Injector / NPV-Tunnel style clients expect;
a strict RFC6455 bridge would not interoperate with them.
"""
import socket, sys, threading

LISTEN_PORT = int(sys.argv[1])
UP_HOST     = sys.argv[2]
UP_PORT     = int(sys.argv[3])
NAME        = sys.argv[4]
BUF_SIZE    = 65536
RESPONSE = (b"HTTP/1.1 101 Switching Protocols\r\n"
            b"Upgrade: websocket\r\nConnection: Upgrade\r\n\r\n")

def tune_socket(sock):
    sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
    try:
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 1 << 20)
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, 1 << 20)
    except OSError:
        pass

def bridge(src, dst):
    try:
        while True:
            data = src.recv(BUF_SIZE)
            if not data:
                break
            dst.sendall(data)
    except Exception:
        pass
    finally:
        for s in (src, dst):
            try: s.close()
            except Exception: pass

def handle(client):
    try:
        tune_socket(client)
        client.settimeout(10)
        client.recv(4096)                 # the client's upgrade request
        client.settimeout(None)
        client.sendall(RESPONSE)
        up = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        tune_socket(up)
        up.settimeout(10)
        up.connect((UP_HOST, UP_PORT))
        up.settimeout(None)
        threading.Thread(target=bridge, args=(client, up), daemon=True).start()
        threading.Thread(target=bridge, args=(up, client), daemon=True).start()
    except Exception as e:
        print(f"[bridge:{NAME}] upstream connect failed: {e}", flush=True)
        try: client.close()
        except Exception: pass

server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
server.bind(('127.0.0.1', LISTEN_PORT))
server.listen(200)
while True:
    c, _ = server.accept()
    threading.Thread(target=handle, args=(c,), daemon=True).start()
