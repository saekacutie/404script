#!/usr/bin/env python3
"""Self-contained tests for ws_bridge.py:  python3 proxies/test_bridge.py  (stdlib only)"""
import asyncio
import base64
import hashlib
import os
import subprocess
import sys
import threading
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "common"))
import ws_bridge  # noqa: E402

KEY = "dGhlIHNhbXBsZSBub25jZQ=="
ACCEPT = base64.b64encode(hashlib.sha1((KEY + ws_bridge.WS_GUID).encode()).digest()).decode()


class Loop:
    """Runs an asyncio loop in a thread so the tests can use plain blocking sockets."""
    def __init__(self):
        self.loop = asyncio.new_event_loop()
        threading.Thread(target=self.loop.run_forever, daemon=True).start()

    def run(self, coro, timeout=10):
        return asyncio.run_coroutine_threadsafe(coro, self.loop).result(timeout)


async def start_echo():
    async def echo(r, w):
        banner = b"SSH-2.0-test\r\n"
        w.write(banner); await w.drain()
        try:
            while True:
                d = await r.read(65536)
                if not d:
                    break
                w.write(d.upper()); await w.drain()
        except ConnectionError:
            pass
        w.close()
    srv = await asyncio.start_server(echo, "127.0.0.1", 0)
    return srv, srv.sockets[0].getsockname()[1]


async def start_bridge(target_port, label="t"):
    srv = await asyncio.start_server(
        lambda r, w: ws_bridge.handle(r, w, "127.0.0.1", target_port, label), "127.0.0.1", 0)
    return srv, srv.sockets[0].getsockname()[1]


async def request(port, raw, read_until=None, then_send=None, expect_bytes=0):
    r, w = await asyncio.open_connection("127.0.0.1", port)
    w.write(raw); await w.drain()
    head = await asyncio.wait_for(r.readuntil(b"\r\n\r\n"), 5)
    body = b""
    if then_send is not None:
        w.write(then_send); await w.drain()
        body = await asyncio.wait_for(r.readexactly(expect_bytes), 5)
    w.close()
    return head, body


UPGRADE = ("GET /saeka-ssh HTTP/1.1\r\nHost: x\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
           "Sec-WebSocket-Key: %s\r\nSec-WebSocket-Version: 13\r\n\r\n" % KEY).encode()


class T(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.L = Loop()
        cls.echo, cls.eport = cls.L.run(start_echo())
        cls.br, cls.bport = cls.L.run(start_bridge(cls.eport))

    def test_upgrade_gets_101_and_bytes_flow_both_ways(self):
        head, body = self.L.run(request(self.bport, UPGRADE, then_send=b"hello", expect_bytes=14 + 5))
        self.assertTrue(head.startswith(b"HTTP/1.1 101 Switching Protocols"))
        self.assertIn(("Sec-WebSocket-Accept: %s" % ACCEPT).encode(), head)
        self.assertEqual(body, b"SSH-2.0-test\r\nHELLO")      # upstream banner + echoed (upper-cased) data

    def test_bytes_sent_right_behind_the_headers_are_kept(self):
        head, body = self.L.run(request(self.bport, UPGRADE + b"early", then_send=b"", expect_bytes=14 + 5))
        self.assertTrue(head.startswith(b"HTTP/1.1 101"))
        self.assertEqual(body, b"SSH-2.0-test\r\nEARLY")

    def test_plain_request_is_health_ok(self):
        head, _ = self.L.run(request(self.bport, b"GET /health HTTP/1.1\r\nHost: x\r\n\r\n"))
        self.assertTrue(head.startswith(b"HTTP/1.1 200 OK"))

    def test_upgrade_without_key_still_101(self):
        raw = b"GET / HTTP/1.1\r\nHost: x\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n"
        head, _ = self.L.run(request(self.bport, raw))
        self.assertTrue(head.startswith(b"HTTP/1.1 101"))
        self.assertNotIn(b"Sec-WebSocket-Accept", head)

    def test_dead_upstream_is_502_not_a_hang(self):
        s, port = self.L.run(start_bridge(1))                       # nothing listens on :1
        head, _ = self.L.run(request(port, UPGRADE), timeout=15)
        self.assertTrue(head.startswith(b"HTTP/1.1 502"))
        self.L.loop.call_soon_threadsafe(s.close)

    def test_many_parallel_tunnels(self):
        async def many():
            res = await asyncio.gather(*[request(self.bport, UPGRADE, then_send=b"n%02d" % i, expect_bytes=14 + 3)
                                         for i in range(60)])
            return [b for _, b in res]
        out = self.L.run(many(), timeout=30)
        self.assertEqual(out, [b"SSH-2.0-test\r\nN%02d" % i for i in range(60)])

    def test_garbage_does_not_kill_the_listener(self):
        async def junk():
            r, w = await asyncio.open_connection("127.0.0.1", self.bport)
            w.write(b"\x00\xff" * 100 + b"\r\n\r\n"); await w.drain(); w.close()
        self.L.run(junk())
        head, _ = self.L.run(request(self.bport, b"GET / HTTP/1.1\r\n\r\n"))
        self.assertTrue(head.startswith(b"HTTP/1.1 200"))

    def test_argument_styles(self):
        a = ws_bridge.parse_args(["2222", "127.0.0.1", "2200", "ssh"])
        self.assertEqual(a, ("127.0.0.1", 2222, "127.0.0.1", 2200, "ssh"))
        b = ws_bridge.parse_args(["--listen", "0.0.0.0:2223", "--target", "10.1.2.3:1194"])
        self.assertEqual(b, ("0.0.0.0", 2223, "10.1.2.3", 1194, "bridge"))
        os.environ.update(BRIDGE_LISTEN_PORT="2225", BRIDGE_TARGET_HOST="h.example", BRIDGE_TARGET_PORT="443")
        c = ws_bridge.parse_args([])
        self.assertEqual(c, ("127.0.0.1", 2225, "h.example", 443, "bridge"))
        for k in ("BRIDGE_LISTEN_PORT", "BRIDGE_TARGET_HOST", "BRIDGE_TARGET_PORT"):
            os.environ.pop(k)
        with self.assertRaises(SystemExit):
            ws_bridge.parse_args(["2222", "", ""])                   # empty target is refused

    def test_real_process_serves_requests(self):
        p = subprocess.Popen([sys.executable, "-I", os.path.join(HERE, "common", "ws_bridge.py"),
                              "--listen", "127.0.0.1:%d" % (self.bport + 1), "--target", "127.0.0.1:%d" % self.eport],
                             stderr=subprocess.PIPE)
        try:
            for _ in range(50):
                try:
                    head, body = self.L.run(request(self.bport + 1, UPGRADE, then_send=b"x", expect_bytes=15))
                    break
                except OSError:
                    import time; time.sleep(0.1)
            self.assertTrue(head.startswith(b"HTTP/1.1 101"))
            self.assertEqual(body, b"SSH-2.0-test\r\nX")
        finally:
            p.terminate(); p.wait(5)


if __name__ == "__main__":
    unittest.main(verbosity=2)
