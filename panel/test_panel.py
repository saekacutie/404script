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
    obj, gen = None, 0
    lock = threading.Lock()

    def log_message(self, *a): pass

    def do_GET(self):
        with FakeGCS.lock:
            if FakeGCS.obj is None:
                self.send_response(404); self.end_headers(); return
            b = FakeGCS.obj
            self.send_response(200); self.send_header("x-goog-generation", str(FakeGCS.gen))
            self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)

    def do_POST(self):
        q = urllib.parse.parse_qs(urllib.parse.urlsplit(self.path).query)
        n = int(self.headers["Content-Length"]); body = self.rfile.read(n)
        with FakeGCS.lock:
            if int(q["ifGenerationMatch"][0]) != FakeGCS.gen:
                self.send_response(412); self.send_header("Content-Length", "0"); self.end_headers(); return
            FakeGCS.obj, FakeGCS.gen = body, FakeGCS.gen + 1
            self.send_response(200); self.send_header("Content-Length", "2"); self.end_headers(); self.wfile.write(b"{}")


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
        srv = ThreadingHTTPServer(("127.0.0.1", 0), FakeGCS); FakeGCS.obj, FakeGCS.gen = None, 0
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


if __name__ == "__main__":
    unittest.main(verbosity=2)
