#!/usr/bin/env python3
"""Small HTTP Upgrade bridge for the Cloud Run/OpenResty SSH-over-WS endpoint.

This is an HTTP transport wrapper only. It does not make SSH, OpenVPN, or
REALITY raw protocols available on Cloud Run; the client must speak the same
upgrade wrapper and the SSH session runs inside the upgraded stream.
"""
import socket
import threading

BUFFER = 65536


def tune(sock):
    sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
    for option in (socket.SO_RCVBUF, socket.SO_SNDBUF):
        try:
            sock.setsockopt(socket.SOL_SOCKET, option, 1 << 20)
        except OSError:
            pass


def pipe(source, target):
    try:
        while True:
            data = source.recv(BUFFER)
            if not data:
                return
            target.sendall(data)
    except (OSError, ConnectionError):
        return
    finally:
        for sock in (source, target):
            try:
                sock.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
            sock.close()


def serve(client):
    ssh = None
    try:
        tune(client)
        request = client.recv(8192)
        if not request:
            return
        first_line = request.split(b"\r\n", 1)[0]
        if not first_line.startswith(b"GET /saeka-ssh"):
            client.sendall(b"HTTP/1.1 404 Not Found\r\nConnection: close\r\n\r\n")
            return
        client.sendall(
            b"HTTP/1.1 101 Switching Protocols\r\n"
            b"Upgrade: websocket\r\n"
            b"Connection: Upgrade\r\n\r\n"
        )
        ssh = socket.create_connection(("127.0.0.1", 22), timeout=10)
        tune(ssh)
        threading.Thread(target=pipe, args=(client, ssh), daemon=True).start()
        pipe(ssh, client)
    except (OSError, ConnectionError):
        pass
    finally:
        for sock in (client, ssh):
            if sock:
                try:
                    sock.close()
                except OSError:
                    pass


def main():
    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind(("127.0.0.1", 2222))
    server.listen(200)
    while True:
        client, _ = server.accept()
        threading.Thread(target=serve, args=(client,), daemon=True).start()


if __name__ == "__main__":
    main()
