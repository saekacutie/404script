#!/usr/bin/env python3
"""Self-contained tests: python3 panel/test_panel.py   (stdlib only)"""
import json, os, sys, tempfile, threading, time, unittest, urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

os.environ["PANEL_KEY"] = "k3y"
os.environ["PANEL_GEOIP"] = "0"
os.environ["PANEL_STATE_FILE"] = os.path.join(tempfile.mkdtemp(), "s.json")
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import server  # noqa: E402


class FakeGCS(BaseHTTPRequestHandler):
    """Name-aware fake bucket: objs[name] = (bytes, generation)."""
    objs = {}
    lock = threading.Lock()

    def log_message(self, *a): pass

    @staticmethod
    def reset():
        FakeGCS.objs = {}

    def do_GET(self):
        path = urllib.parse.urlsplit(self.path).path
        name = urllib.parse.unquote(path.split("/o/", 1)[1])
        with FakeGCS.lock:
            if name not in FakeGCS.objs:
                self.send_response(404); self.send_header("Content-Length", "0"); self.end_headers(); return
            b, gen = FakeGCS.objs[name]
            self.send_response(200); self.send_header("x-goog-generation", str(gen))
            self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)

    def do_POST(self):
        q = urllib.parse.parse_qs(urllib.parse.urlsplit(self.path).query)
        n = int(self.headers["Content-Length"]); body = self.rfile.read(n)
        name = q["name"][0]
        with FakeGCS.lock:
            gen = FakeGCS.objs.get(name, (b"", 0))[1]
            if int(q["ifGenerationMatch"][0]) != gen:
                self.send_response(412); self.send_header("Content-Length", "0"); self.end_headers(); return
            FakeGCS.objs[name] = (body, gen + 1)
            self.send_response(200); self.send_header("Content-Length", "2"); self.end_headers(); self.wfile.write(b"{}")


class FakeGCS2(FakeGCS):
    """Separate object store so the registry test never shares state with the counter test."""
    obj, gen = None, 0
    lock = threading.Lock()

    def do_GET(self):
        with FakeGCS2.lock:
            if FakeGCS2.obj is None:
                self.send_response(404); self.end_headers(); return
            b = FakeGCS2.obj
            self.send_response(200); self.send_header("x-goog-generation", str(FakeGCS2.gen))
            self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)

    def do_POST(self):
        q = urllib.parse.parse_qs(urllib.parse.urlsplit(self.path).query)
        n = int(self.headers["Content-Length"]); body = self.rfile.read(n)
        with FakeGCS2.lock:
            if int(q["ifGenerationMatch"][0]) != FakeGCS2.gen:
                self.send_response(412); self.send_header("Content-Length", "0"); self.end_headers(); return
            FakeGCS2.obj, FakeGCS2.gen = body, FakeGCS2.gen + 1
            self.send_response(200); self.send_header("Content-Length", "2"); self.end_headers(); self.wfile.write(b"{}")


def peer_server(healthy=True):
    class P(BaseHTTPRequestHandler):
        def log_message(self, *a): pass
        def do_GET(self):
            if self.path.endswith("/api/health") and healthy:
                b = b'{"ok":true,"panel":"saeka","up":5}'; self.send_response(200)
            else:
                b = b"{}"; self.send_response(404)
            self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)
    srv = ThreadingHTTPServer(("127.0.0.1", 0), P)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    return srv


class T(unittest.TestCase):
    def test_flag(self):
        self.assertEqual(server.flag("us"), "\U0001F1FA\U0001F1F8")
        self.assertEqual(server.flag("PH"), "\U0001F1F5\U0001F1ED")
        self.assertEqual(server.flag(""), "\U0001F310")
        self.assertEqual(server.flag("x1"), "\U0001F310")

    def test_regions_complete(self):
        for r, (city, country, cc, lat, lon) in server.REGIONS.items():
            self.assertEqual(len(cc), 2, r); self.assertTrue(-90 <= lat <= 90 and -180 <= lon <= 180, r)

    def test_host_region(self):
        f = server.Where._from_host
        self.assertEqual(f("svc-123456789.us-east1.run.app")["region"], "us-east1")
        self.assertEqual(f("x-1.europe-west9.run.app:443")["region"], "europe-west9")
        self.assertEqual(f("x-1.northamerica-northeast1.run.app")["cc"], "CA")
        self.assertIsNone(f("example.com"))
        self.assertIsNone(f("svc-abc-uc.a.run.app"))

    def test_session(self):
        self.assertTrue(server.valid_session(server.make_session()))
        self.assertFalse(server.valid_session("1.deadbeef"))
        self.assertFalse(server.valid_session("9999999999.00"))
        self.assertFalse(server.valid_session("junk"))

    def test_merge_and_unique(self):
        st = server.merge_state(None, 2, ["a", "b"], {"2026-01-01": 2}, [], "n1", {"ts": time.time(), "online": 1, "vids": ["a"]})
        st = server.merge_state(st, 1, ["b", "c"], {"2026-01-01": 1}, [], "n2", {"ts": time.time(), "online": 1, "vids": ["c"]})
        self.assertEqual((st["total"], st["unique"], st["peak"]), (3, 3, 2))
        self.assertEqual(st["days"]["2026-01-01"], 3)
        self.assertEqual(set(st["nodes"]), {"n1", "n2"})

    def _store(self, port):
        os.environ["PANEL_BUCKET"] = "b"; os.environ["PANEL_GCS_TOKEN"] = "t"
        os.environ["PANEL_GCS_ENDPOINT"] = "http://127.0.0.1:%d" % port
        return server.Store()

    def test_gcs_cas_two_nodes(self):
        srv = ThreadingHTTPServer(("127.0.0.1", 0), FakeGCS); FakeGCS.reset()
        threading.Thread(target=srv.serve_forever, daemon=True).start()
        a, b = self._store(srv.server_port), self._store(srv.server_port)
        self.assertEqual(a.mode, "gcs")
        for i in range(5): a.pulse("a%015d" % i, "1.1.1.1", True)
        for i in range(4): b.pulse("b%015d" % i, "2.2.2.2", True)
        b.pulse("a%015d" % 0, "2.2.2.2", True)         # same browser seen on another node -> visit, not unique
        ts = [threading.Thread(target=s.flush) for s in (a, b)]
        [t.start() for t in ts]; [t.join() for t in ts]
        a.flush(); b.flush()
        for s in (a, b):
            snap = s.snapshot()
            self.assertEqual(snap["total"], 10); self.assertEqual(snap["unique"], 9)
            self.assertEqual(snap["nodes"], 2); self.assertEqual(snap["store"], "gcs"); self.assertTrue(snap["synced"])
        self.assertEqual(snap["online"], 9)
        srv.shutdown()

    def test_gcs_down_degrades(self):
        s = self._store(1)          # nothing listens on :1
        s.pulse("c%015d" % 1, "3.3.3.3", True)
        self.assertFalse(s.flush())
        snap = s.snapshot()
        self.assertEqual(snap["total"], 1); self.assertEqual(snap["store"], "local"); self.assertFalse(snap["synced"])

    def test_gcs_permission_denied_is_explained(self):
        class Denied(BaseHTTPRequestHandler):
            def log_message(self, *a): pass
            def do_GET(self):
                body = json.dumps({"error": {"code": 403, "message": "sa@p.iam lacks storage.objects.get"}}).encode()
                self.send_response(403); self.send_header("Content-Length", str(len(body)))
                self.end_headers(); self.wfile.write(body)
        srv = ThreadingHTTPServer(("127.0.0.1", 0), Denied)
        threading.Thread(target=srv.serve_forever, daemon=True).start()
        s = self._store(srv.server_port)
        s.pulse("f" * 16, "6.6.6.6", True)
        self.assertFalse(s.flush())
        self.assertIn("HTTP 403", s.err)
        self.assertIn("lacks storage.objects.get", s.err)        # Google's own message is kept
        self.assertIn("roles/storage.objectAdmin", s.err)         # and the fix is named
        self.assertEqual(s.fail_n, 1)
        self.assertGreater(s.retry_at, time.time())               # backs off instead of hammering
        self.assertEqual(s.snapshot()["store"], "local")          # UI degrades honestly
        srv.shutdown()

    def test_visit_dedupe_and_ip_cap(self):
        os.environ.pop("PANEL_BUCKET", None)
        s = server.Store()
        self.assertTrue(s.pulse("d" * 16, "4.4.4.4", True))
        self.assertFalse(s.pulse("d" * 16, "4.4.4.4", True))      # same browser inside 30 min
        n = sum(s.pulse("e%015d" % i, "5.5.5.5", True) for i in range(40))
        self.assertEqual(n, 20)                                    # one IP can't pump the counter

    def test_endpoints_from_real_config(self):
        cfg = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "common", "config-noads.json")
        server.XRAY_CONFIG = cfg; server._cfg_cache.update(mtime=None, data=None)
        eps, _ = server.load_endpoints()
        self.assertEqual(len(eps), 21)
        self.assertEqual({e["family"] for e in eps}, {"vless", "vmess", "trojan", "ss", "ssh"})
        v = next(e for e in eps if e["tag"] == "vless-ws"); self.assertEqual((v["path"], v["cred"]["id"]), ("/vless-saeka", "saeka"))
        g = next(e for e in eps if e["tag"] == "ss-grpc"); self.assertEqual(g["service"], "ss-saeka-grpc")
        server.ENGINE = "openresty"
        self.assertFalse(server.engine_support("grpc")[0]); self.assertTrue(server.engine_support("ws")[0])
        server.ENGINE = "unknown"

    def test_registry_finds_every_deployment(self):
        """Two deployments share one registry object; each sees the other; dead / foreign ones are flagged."""
        import re
        gcs = ThreadingHTTPServer(("127.0.0.1", 0), FakeGCS2); FakeGCS2.obj, FakeGCS2.gen = None, 0
        threading.Thread(target=gcs.serve_forever, daemon=True).start()
        peer_a, peer_b = peer_server(), peer_server(healthy=False)
        saved = (server.HOST_RE, server.PEER_URL)
        server.HOST_RE = re.compile(r"^[0-9.]+:[0-9]+$"); server.PEER_URL = "http://{host}{base}"
        try:
            cfg = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "common", "config-noads.json")
            server.XRAY_CONFIG = cfg; server._cfg_cache.update(mtime=None, data=None)
            os.environ["PANEL_REGISTRY_BUCKET"] = "reg"
            a, b = server.Registry(self._store(gcs.server_port)), server.Registry(self._store(gcs.server_port))
            a.self_host = "127.0.0.1:%d" % peer_a.server_port
            b.self_host = "127.0.0.1:%d" % peer_b.server_port
            self.assertEqual(a.mode, "gcs")
            self.assertTrue(a.heartbeat(force=True)); self.assertTrue(b.heartbeat(force=True))
            la = a.listing()
            self.assertEqual({x["host"] for x in la["servers"]}, {a.self_host, b.self_host})
            me = next(x for x in la["servers"] if x["self"]); self.assertEqual(me["host"], a.self_host); self.assertTrue(me["up"])
            other = next(x for x in la["servers"] if not x["self"])
            self.assertFalse(other["up"])                      # peer_b answers 404 -> reported down, not hidden
            self.assertTrue(other["same_login"])               # same config -> same credentials
            self.assertEqual(la["servers"][0]["host"], a.self_host)
            # manual add: a reachable panel is accepted, an unreachable one is refused
            extra = peer_server()
            a.add("127.0.0.1:%d" % extra.server_port)
            self.assertEqual(len(a.listing()["servers"]), 3)
            with self.assertRaises(ValueError): a.add("127.0.0.1:%d" % peer_b.server_port)
            with self.assertRaises(ValueError): a.add("evil.example.com")
            a.forget("127.0.0.1:%d" % extra.server_port)
            self.assertEqual(len(b.listing()["servers"]), 2)    # b sees the removal through the shared object
            with self.assertRaises(ValueError): a.forget(a.self_host)
            # a different login on another deployment is flagged
            b.mutate(lambda sv: sv[b.self_host].update(cred="deadbeef00"))
            self.assertFalse(next(x for x in a.listing()["servers"] if x["host"] == b.self_host)["same_login"])
        finally:
            server.HOST_RE, server.PEER_URL = saved
            os.environ.pop("PANEL_REGISTRY_BUCKET", None)
            for x in (gcs, peer_a, peer_b): x.shutdown()

    def test_registry_local_creates_itself(self):
        os.environ.pop("PANEL_BUCKET", None); os.environ.pop("PANEL_REGISTRY_BUCKET", None)
        os.environ["PANEL_REGISTRY_FILE"] = os.path.join(tempfile.mkdtemp(), "r.json")
        r = server.Registry(server.Store())
        self.assertEqual(r.mode, "local")
        r.note_host("my-svc-123456789.asia-southeast1.run.app")
        self.assertEqual(r.self_host, "my-svc-123456789.asia-southeast1.run.app")
        self.assertTrue(r.heartbeat(force=True))               # no registry yet -> this call creates it
        d = r.listing()
        self.assertEqual([x["host"] for x in d["servers"]], [r.self_host])
        self.assertEqual(d["servers"][0]["region"], "asia-southeast1")
        r.note_host("evil.example.com"); self.assertEqual(r.self_host, "my-svc-123456789.asia-southeast1.run.app")
        self.assertFalse(server.HOST_RE.match("a.b.example.com"))
        self.assertTrue(server.HOST_RE.match("svc-abc-uc.a.run.app"))


if __name__ == "__main__":
    unittest.main(verbosity=2)
