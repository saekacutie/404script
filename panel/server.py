#!/usr/bin/env python3
"""
SAEKA PANEL - backend  (python3 stdlib only, no pip packages)

Runs next to the proxy engine inside the same container and listens on
127.0.0.1:10030.  Every engine forwards ONE prefix to it: /saeka-panel
Nothing else on the proxy side is touched, so a crash or restart of this
process can never affect VLESS / VMess / Trojan / Shadowsocks / SSH traffic.

What it does
  * serves the single-file UI (index.html)
  * reads the REAL credentials + inbounds from /etc/xray/config.json on every
    request (mtime-cached), builds endpoint data for share links, and probes
    each inbound with a real TCP connect
  * detects the real region: Cloud Run / GCE metadata server -> run.app
    hostname -> GeoIP of the egress IP
  * counts visits / online visitors; totals are persisted in a GCS object
    (PANEL_BUCKET, optimistic concurrency so several Cloud Run instances can
    share one counter) or a local file when no bucket is configured
  * secrets (credentials, visitor locations) only after login with PANEL_KEY
"""
import base64
import gzip
import hashlib
import hmac
import ipaddress
import json
import os
import re
import secrets
import signal
import socket
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from collections import deque
from concurrent.futures import ThreadPoolExecutor
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

BASE = ""                    # the panel lives at the service root: https://<service>.run.app/
LEGACY_BASE = "/saeka-panel"   # old deployments / bookmarks keep working
HERE = os.path.dirname(os.path.abspath(__file__))
STARTED = time.time()

BIND = os.environ.get("PANEL_BIND", "127.0.0.1")
PORT = int(os.environ.get("PANEL_PORT", "10030"))
XRAY_CONFIG = os.environ.get("XRAY_CONFIG", "/etc/xray/config.json")
ENGINE = os.environ.get("PANEL_ENGINE", "unknown").lower()
INDEX_FILE = os.environ.get("PANEL_INDEX", os.path.join(HERE, "index.html"))
GEOIP_ON = os.environ.get("PANEL_GEOIP", "1") != "0"
SESSION_TTL = 12 * 3600
VISIT_GAP = 30 * 60          # same browser inside 30 min = same visit
ONLINE_WINDOW = 15           # seconds since last pulse = "online now"
NODE_WINDOW = 30             # other instances' presence stays valid this long


def log(*a):
    print("[panel]", *a, flush=True)


# --------------------------------------------------------------------------
# Regions (GCP). city, country, ISO-3166 alpha-2, lat, lon
# --------------------------------------------------------------------------
REGIONS = {
    "us-central1": ("Council Bluffs, Iowa", "United States", "US", 41.26, -95.86),
    "us-east1": ("Moncks Corner, South Carolina", "United States", "US", 33.20, -80.01),
    "us-east4": ("Ashburn, Virginia", "United States", "US", 39.04, -77.49),
    "us-east5": ("Columbus, Ohio", "United States", "US", 39.96, -82.99),
    "us-south1": ("Dallas, Texas", "United States", "US", 32.78, -96.80),
    "us-west1": ("The Dalles, Oregon", "United States", "US", 45.59, -121.18),
    "us-west2": ("Los Angeles, California", "United States", "US", 34.05, -118.24),
    "us-west3": ("Salt Lake City, Utah", "United States", "US", 40.76, -111.89),
    "us-west4": ("Las Vegas, Nevada", "United States", "US", 36.17, -115.14),
    "northamerica-northeast1": ("Montreal", "Canada", "CA", 45.50, -73.57),
    "northamerica-northeast2": ("Toronto", "Canada", "CA", 43.65, -79.38),
    "northamerica-south1": ("Queretaro", "Mexico", "MX", 20.59, -100.39),
    "southamerica-east1": ("Sao Paulo", "Brazil", "BR", -23.55, -46.63),
    "southamerica-west1": ("Santiago", "Chile", "CL", -33.45, -70.67),
    "europe-west1": ("St. Ghislain", "Belgium", "BE", 50.45, 3.82),
    "europe-west2": ("London", "United Kingdom", "GB", 51.51, -0.13),
    "europe-west3": ("Frankfurt", "Germany", "DE", 50.11, 8.68),
    "europe-west4": ("Eemshaven", "Netherlands", "NL", 53.44, 6.83),
    "europe-west6": ("Zurich", "Switzerland", "CH", 47.38, 8.54),
    "europe-west8": ("Milan", "Italy", "IT", 45.46, 9.19),
    "europe-west9": ("Paris", "France", "FR", 48.86, 2.35),
    "europe-west10": ("Berlin", "Germany", "DE", 52.52, 13.40),
    "europe-west12": ("Turin", "Italy", "IT", 45.07, 7.69),
    "europe-north1": ("Hamina", "Finland", "FI", 60.57, 27.20),
    "europe-north2": ("Stockholm", "Sweden", "SE", 59.33, 18.07),
    "europe-central2": ("Warsaw", "Poland", "PL", 52.23, 21.01),
    "europe-southwest1": ("Madrid", "Spain", "ES", 40.42, -3.70),
    "asia-east1": ("Changhua County", "Taiwan", "TW", 24.07, 120.54),
    "asia-east2": ("Hong Kong", "Hong Kong", "HK", 22.32, 114.17),
    "asia-northeast1": ("Tokyo", "Japan", "JP", 35.68, 139.69),
    "asia-northeast2": ("Osaka", "Japan", "JP", 34.69, 135.50),
    "asia-northeast3": ("Seoul", "South Korea", "KR", 37.57, 126.98),
    "asia-south1": ("Mumbai", "India", "IN", 19.08, 72.88),
    "asia-south2": ("Delhi", "India", "IN", 28.61, 77.21),
    "asia-southeast1": ("Jurong West", "Singapore", "SG", 1.35, 103.82),
    "asia-southeast2": ("Jakarta", "Indonesia", "ID", -6.21, 106.85),
    "asia-southeast3": ("Bangkok", "Thailand", "TH", 13.76, 100.50),
    "australia-southeast1": ("Sydney", "Australia", "AU", -33.87, 151.21),
    "australia-southeast2": ("Melbourne", "Australia", "AU", -37.81, 144.96),
    "me-central1": ("Doha", "Qatar", "QA", 25.29, 51.53),
    "me-central2": ("Dammam", "Saudi Arabia", "SA", 26.43, 50.10),
    "me-west1": ("Tel Aviv", "Israel", "IL", 32.09, 34.78),
    "africa-south1": ("Johannesburg", "South Africa", "ZA", -26.20, 28.05),
}
REGION_RE = re.compile(r"^[a-z]+(?:-[a-z]+)*[0-9]+$")


def flag(cc):
    """ISO alpha-2 -> emoji flag (regional indicator pair)."""
    if not cc or not re.fullmatch(r"[A-Za-z]{2}", cc):
        return "\U0001F310"
    return "".join(chr(0x1F1E6 + ord(c) - 65) for c in cc.upper())


def region_info(region, source):
    row = REGIONS.get(region)
    if not row:
        return None
    city, country, cc, lat, lon = row
    return {"region": region, "city": city, "country": country, "cc": cc,
            "flag": flag(cc), "lat": lat, "lon": lon, "source": source}


# --------------------------------------------------------------------------
# small http helper (used for metadata / geoip / GCS)
# --------------------------------------------------------------------------
def http_get(url, headers=None, timeout=2.0):
    req = urllib.request.Request(url, headers=headers or {})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.read().decode("utf-8", "replace")


def metadata(path, timeout=1.2):
    return http_get("http://metadata.google.internal/computeMetadata/v1/" + path,
                    {"Metadata-Flavor": "Google"}, timeout).strip()


def is_public_ip(s):
    try:
        ip = ipaddress.ip_address(s)
    except ValueError:
        return False
    return not (ip.is_private or ip.is_loopback or ip.is_link_local or
                ip.is_multicast or ip.is_reserved or ip.is_unspecified)


# --------------------------------------------------------------------------
# server / region detection
# --------------------------------------------------------------------------
class Where:
    def __init__(self):
        self.lock = threading.Lock()
        self.busy = threading.Lock()
        self.info = None
        self.provider = "Self-hosted"
        self.checked = 0.0
        self.next_try = 0.0

    @staticmethod
    def _from_host(host_hint):
        """<service>-<number>.<region>.run.app -> region (no network needed)."""
        m = re.search(r"\.([a-z]+(?:-[a-z]+)*[0-9]+)\.run\.app$", (host_hint or "").split(":")[0].lower())
        return region_info(m.group(1), "hostname") if m else None

    def _detect(self):
        env = os.environ.get("PANEL_REGION", "").strip().lower()
        if env and region_info(env, "env"):
            return region_info(env, "env"), "Google Cloud"
        # 1. metadata server (Cloud Run: instance/region, GCE: instance/zone)
        try:
            region = metadata("instance/region").rsplit("/", 1)[-1]
            info = region_info(region, "metadata")
            if info:
                return info, ("Google Cloud Run" if os.environ.get("K_SERVICE") else "Google Cloud")
            if REGION_RE.match(region):
                return {"region": region, "city": region, "country": "", "cc": "",
                        "flag": flag(""), "lat": None, "lon": None, "source": "metadata"}, "Google Cloud"
        except Exception:
            pass
        try:
            zone = metadata("instance/zone").rsplit("/", 1)[-1]
            info = region_info(zone.rsplit("-", 1)[0], "metadata")
            if info:
                return info, "Google Compute Engine"
        except Exception:
            pass
        # 2. GeoIP of our own egress address (VPS etc.)
        if GEOIP_ON:
            try:
                d = json.loads(http_get(
                    "http://ip-api.com/json/?fields=status,country,countryCode,regionName,city,lat,lon",
                    timeout=3.0))
                if d.get("status") == "success":
                    cc = d.get("countryCode", "")
                    return {"region": (d.get("city") or d.get("regionName") or "").lower() or "unknown",
                            "city": ", ".join(x for x in (d.get("city"), d.get("regionName")) if x),
                            "country": d.get("country", ""), "cc": cc, "flag": flag(cc),
                            "lat": d.get("lat"), "lon": d.get("lon"), "source": "geoip"}, "Self-hosted"
            except Exception:
                pass
        return None, "Self-hosted"

    def get(self, host_hint=None):
        with self.lock:
            now = time.time()
            if self.info is not None and now - self.checked < 900:
                return self.info, self.provider
            if self.info is None:                       # instant answer from the hostname
                quick = self._from_host(host_hint)
                if quick:
                    self.info, self.provider = quick, "Google Cloud Run"
            if now < self.next_try:
                return self.info, self.provider
        if not self.busy.acquire(blocking=False):      # another thread is already detecting
            return self.info, self.provider
        try:
            info, provider = self._detect()
            with self.lock:
                if info:
                    self.info, self.provider = info, provider
                    self.checked = time.time()
                else:
                    self.next_try = time.time() + 30
        finally:
            self.busy.release()
        with self.lock:
            return self.info, self.provider


WHERE = Where()


# --------------------------------------------------------------------------
# xray config -> endpoints
# --------------------------------------------------------------------------
_cfg_cache = {"mtime": None, "data": None}
VARIANTS = (("-ws", "ws"), ("-hu", "hu"), ("-xh", "xh"), ("-grpc", "grpc"), ("-h2", "h2"))
FAMILY = {"vless": "vless", "vmess": "vmess", "trojan": "trojan", "shadowsocks": "ss"}


def engine_support(variant):
    """(supported, note) for a transport on the running engine."""
    if ENGINE == "openresty" and variant in ("grpc", "h2"):
        return False, "OpenResty/nginx cannot serve gRPC or H2 on one cleartext port (returns 501)."
    if ENGINE == "haproxy" and variant in ("grpc", "h2"):
        return True, "HAProxy on Cloud Run: gRPC/H2 only works if the service was deployed with --use-http2."
    return True, ""


def load_endpoints():
    try:
        st = os.stat(XRAY_CONFIG)
    except OSError:
        return [], None
    if _cfg_cache["mtime"] == st.st_mtime and _cfg_cache["data"] is not None:
        return _cfg_cache["data"], st.st_mtime
    with open(XRAY_CONFIG, "r", encoding="utf-8") as fh:
        cfg = json.load(fh)
    out = []
    for ib in cfg.get("inbounds", []):
        proto = ib.get("protocol", "")
        tag = ib.get("tag", "")
        ss = ib.get("streamSettings", {}) or {}
        net = ss.get("network", "tcp")
        settings = ib.get("settings", {}) or {}
        ep = {"tag": tag, "port": ib.get("port"), "network": net}
        if proto == "dokodemo-door":
            ep.update(family="ssh", variant="ws", path=(ss.get("wsSettings") or {}).get("path", "/saeka-ssh"),
                      label="SSH over WebSocket")
            ep["supported"], ep["note"] = True, ""
            out.append(ep)
            continue
        if proto not in FAMILY:
            continue
        variant = next((v for suf, v in VARIANTS if tag.endswith(suf)), net)
        ep["family"] = FAMILY[proto]
        ep["variant"] = variant
        if net == "ws":
            ep["path"] = (ss.get("wsSettings") or {}).get("path", "/")
        elif net == "httpupgrade":
            ep["path"] = (ss.get("httpupgradeSettings") or {}).get("path", "/")
        elif net in ("xhttp", "splithttp"):
            x = ss.get("xhttpSettings") or ss.get("splithttpSettings") or {}
            ep["path"] = x.get("path", "/")
            ep["mode"] = x.get("mode", "auto")
        elif net == "grpc":
            ep["service"] = (ss.get("grpcSettings") or {}).get("serviceName", "")
        clients = settings.get("clients") or []
        c = clients[0] if clients else {}
        if proto in ("vless", "vmess"):
            ep["cred"] = {"id": c.get("id", "")}
        elif proto == "trojan":
            ep["cred"] = {"password": c.get("password", "")}
        else:
            ep["cred"] = {"password": c.get("password", ""), "method": c.get("method", "aes-256-gcm")}
        ep["supported"], ep["note"] = engine_support(variant)
        out.append(ep)
    _cfg_cache.update(mtime=st.st_mtime, data=out)
    return out, st.st_mtime


def tcp_probe(port):
    t0 = time.perf_counter()
    try:
        with socket.create_connection(("127.0.0.1", int(port)), 0.5):
            return True, round((time.perf_counter() - t0) * 1000, 1)
    except Exception:
        return False, None


def probe_all(endpoints):
    if not endpoints:
        return
    with ThreadPoolExecutor(max_workers=8) as ex:
        for ep, (ok, ms) in zip(endpoints, ex.map(lambda e: tcp_probe(e["port"]), endpoints)):
            ep["up"], ep["probe_ms"] = ok, ms


def ssh_users():
    out = []
    for pair in filter(None, os.environ.get("SSH_USERS", "").split(",")):
        user, _, pw = pair.partition(":")
        if user:
            out.append({"user": user, "password": pw})
    return out


# --------------------------------------------------------------------------
# visitor geo (best effort, cached, never blocks the proxy)
# --------------------------------------------------------------------------
class Geo:
    def __init__(self):
        self.cache = {}
        self.lock = threading.Lock()
        self.gate = threading.Lock()
        self.last_call = 0.0

    def lookup(self, ip, block=False):
        if not GEOIP_ON or not ip or not is_public_ip(ip):
            return None
        with self.lock:
            hit = self.cache.get(ip)
            if hit and time.time() - hit["ts"] < 6 * 3600:
                return hit
        if not block:
            threading.Thread(target=self._fetch, args=(ip,), daemon=True).start()
            return None
        return self._fetch(ip, timeout=1.6)

    def _fetch(self, ip, timeout=3.0):
        with self.gate:                      # free tier is ~45 req/min
            wait = 1.5 - (time.time() - self.last_call)
            if wait > 0:
                time.sleep(wait)
            self.last_call = time.time()
            try:
                d = json.loads(http_get(
                    "http://ip-api.com/json/%s?fields=status,countryCode,city,lat,lon" % ip, timeout=timeout))
            except Exception:
                d = {}
        if d.get("status") != "success":
            rec = {"cc": "", "city": "", "lat": None, "lon": None, "ts": time.time()}
        else:
            rec = {"cc": d.get("countryCode", ""), "city": d.get("city", ""),
                   "lat": round(float(d["lat"]) * 2) / 2, "lon": round(float(d["lon"]) * 2) / 2,
                   "ts": time.time()}
        with self.lock:
            if len(self.cache) > 2000:
                self.cache.clear()
            self.cache[ip] = rec
        return rec


GEO = Geo()


# --------------------------------------------------------------------------
# shared visit store
# --------------------------------------------------------------------------
def today():
    return time.strftime("%Y-%m-%d", time.gmtime())


def empty_state():
    return {"v": 1, "since": int(time.time()), "total": 0, "unique": 0, "peak": 0,
            "days": {}, "vids": [], "feed": [], "nodes": {}}


def merge_state(remote, d_total, d_vids, d_days, d_feed, iid, node_entry):
    """Pure merge of this node's pending deltas into the shared state."""
    st = remote if isinstance(remote, dict) and remote.get("v") == 1 else empty_state()
    st.setdefault("days", {}); st.setdefault("vids", []); st.setdefault("feed", []); st.setdefault("nodes", {})
    st["total"] = int(st.get("total", 0)) + d_total
    known = set(st["vids"])
    fresh = []
    for v in d_vids:
        if v not in known:
            known.add(v)
            fresh.append(v)
    st["unique"] = int(st.get("unique", 0)) + len(fresh)
    st["vids"] = (st["vids"] + fresh)[-5000:]
    for d, n in d_days.items():
        st["days"][d] = int(st["days"].get(d, 0)) + n
    for d in sorted(st["days"])[:-30]:
        del st["days"][d]
    st["feed"] = sorted(st["feed"] + d_feed, key=lambda e: e.get("t", 0))[-20:]
    now = time.time()
    st["nodes"][iid] = node_entry
    st["nodes"] = {k: v for k, v in st["nodes"].items() if now - v.get("ts", 0) < 120}
    live = set()
    for v in st["nodes"].values():
        if now - v.get("ts", 0) < NODE_WINDOW:
            live.update(v.get("vids", []))
    st["peak"] = max(int(st.get("peak", 0)), len(live))
    return st


def explain_gcs_error(e):
    """One readable line for a failed GCS call: HTTP status + Google's own message,
    plus the usual fix for permission errors (the bare 'HTTP Error 403: Forbidden'
    that urllib gives says nothing about which identity or bucket was refused)."""
    if isinstance(e, urllib.error.HTTPError):
        msg = ""
        try:
            msg = json.loads(e.read().decode("utf-8", "replace")).get("error", {}).get("message", "")
        except Exception:
            pass
        hint = ""
        if e.code in (401, 403):
            hint = (" -> the service's runtime service account needs roles/storage.objectAdmin "
                    "on the PANEL_BUCKET bucket")
        elif e.code == 404:
            hint = " -> the PANEL_BUCKET bucket does not exist"
        return "HTTP %d%s%s" % (e.code, (": " + msg) if msg else "", hint)
    return "%s: %s" % (type(e).__name__, e)


class Store:
    def __init__(self):
        self.lock = threading.RLock()
        self.fail_n = 0          # consecutive failed syncs (drives the retry backoff)
        self.retry_at = 0.0      # don't try again before this time
        self.iid = secrets.token_hex(3)
        self.bucket = os.environ.get("PANEL_BUCKET", "").strip()
        self.obj = os.environ.get("PANEL_OBJECT", "panel/state.json")
        self.gcs_base = os.environ.get("PANEL_GCS_ENDPOINT", "https://storage.googleapis.com").rstrip("/")
        self.file = os.environ.get("PANEL_STATE_FILE", "/tmp/saeka-panel-state.json")
        self.mode = "gcs" if self.bucket else "local"
        self.view = empty_state()
        self.vidset = set()
        self.d_total = 0
        self.d_vids = []
        self.d_days = {}
        self.d_feed = []
        self.presence = {}       # vid -> {"t", "ip"}
        self.last_visit = {}     # vid -> ts of last counted visit (this node)
        self.ip_visits = {}      # ip -> [ts...]
        self.dirty = False
        self.ok = None
        self.err = ""
        self.last_sync = 0.0
        self._tok = None
        self._tok_exp = 0.0
        self._load_local_boot()

    # ---- boot: load whatever we have so numbers show instantly
    def _load_local_boot(self):
        try:
            with open(self.file, "r", encoding="utf-8") as fh:
                st = json.load(fh)
            if st.get("v") == 1 and self.mode == "local":
                self.view = st
                self.vidset = set(st.get("vids", []))
        except Exception:
            pass

    # ---- GCS io
    def _token(self):
        env = os.environ.get("PANEL_GCS_TOKEN")
        if env:
            return env
        if self._tok and time.time() < self._tok_exp - 60:
            return self._tok
        d = json.loads(metadata("instance/service-accounts/default/token", timeout=2.0))
        self._tok = d["access_token"]
        self._tok_exp = time.time() + int(d.get("expires_in", 300))
        return self._tok

    def _gcs_req(self, url, data=None, ctype=None):
        h = {"Authorization": "Bearer " + self._token()}
        if ctype:
            h["Content-Type"] = ctype
        req = urllib.request.Request(url, data=data, headers=h, method="POST" if data is not None else "GET")
        return urllib.request.urlopen(req, timeout=6)

    def _gcs_get(self, obj=None):
        url = "%s/storage/v1/b/%s/o/%s?alt=media" % (
            self.gcs_base, urllib.parse.quote(self.bucket, safe=""), urllib.parse.quote(obj or self.obj, safe=""))
        try:
            with self._gcs_req(url) as r:
                return json.loads(r.read().decode()), int(r.headers.get("x-goog-generation", "0") or 0)
        except urllib.error.HTTPError as e:
            if e.code == 404:
                return None, 0
            raise

    def _gcs_put(self, data, gen, obj=None):
        url = "%s/upload/storage/v1/b/%s/o?uploadType=media&name=%s&ifGenerationMatch=%d" % (
            self.gcs_base, urllib.parse.quote(self.bucket, safe=""), urllib.parse.quote(obj or self.obj, safe=""), gen)
        with self._gcs_req(url, json.dumps(data).encode(), "application/json"):
            return True

    # ---- flush
    def flush(self):
        with self.lock:
            dt, dv, dd, df = self.d_total, list(self.d_vids), dict(self.d_days), list(self.d_feed)
            now = time.time()
            live = [v for v, p in self.presence.items() if now - p["t"] <= ONLINE_WINDOW]
            node = {"ts": now, "online": len(live), "vids": live[:200]}
        try:
            if self.mode == "gcs":
                merged = None
                for _ in range(6):
                    remote, gen = self._gcs_get()
                    merged = merge_state(remote, dt, dv, dd, df, self.iid, node)
                    try:
                        self._gcs_put(merged, gen)
                        break
                    except urllib.error.HTTPError as e:
                        if e.code != 412:
                            raise
                        merged = None
                if merged is None:
                    raise RuntimeError("GCS write kept losing the race")
            else:
                try:
                    with open(self.file, "r", encoding="utf-8") as fh:
                        remote = json.load(fh)
                except Exception:
                    remote = None
                merged = merge_state(remote, dt, dv, dd, df, self.iid, node)
                tmp = self.file + ".tmp"
                with open(tmp, "w", encoding="utf-8") as fh:
                    json.dump(merged, fh)
                os.replace(tmp, self.file)
        except Exception as e:
            with self.lock:
                self.ok, self.err = False, explain_gcs_error(e)
                self.fail_n += 1
                # back off 2s, 4s, 8s ... capped at 60s so a permission problem
                # doesn't hammer the metadata server and GCS every flusher tick
                self.retry_at = time.time() + min(60, 2 ** self.fail_n)
            log("sync failed:", self.err)
            return False
        with self.lock:
            self.fail_n, self.retry_at = 0, 0.0
            self.d_total -= dt
            sent = set(dv)
            self.d_vids = [v for v in self.d_vids if v not in sent]
            for d, n in dd.items():
                left = self.d_days.get(d, 0) - n
                if left > 0:
                    self.d_days[d] = left
                else:
                    self.d_days.pop(d, None)
            self.d_feed = [e for e in self.d_feed if e not in df]
            self.view = merged
            self.vidset = set(merged.get("vids", []))
            self.ok, self.err, self.last_sync = True, "", time.time()
            self.dirty = bool(self.d_total or self.d_vids)
        return True

    # ---- events
    def pulse(self, vid, ip, newvisit, geo=None):
        now = time.time()
        with self.lock:
            self.presence[vid] = {"t": now, "ip": ip}
            if len(self.presence) > 5000:
                self._prune(now)
            if not newvisit or now - self.last_visit.get(vid, 0) < VISIT_GAP:
                return False
            hist = [t for t in self.ip_visits.get(ip, []) if now - t < 3600]
            if len(hist) >= 20:                      # one address can't pump the counter
                self.ip_visits[ip] = hist
                return False
            hist.append(now)
            self.ip_visits[ip] = hist
            self.last_visit[vid] = now
            self.d_total += 1
            day = today()
            self.d_days[day] = self.d_days.get(day, 0) + 1
            if vid not in self.vidset and vid not in self.d_vids:
                self.d_vids.append(vid)
            entry = {"t": int(now)}
            if geo and geo.get("cc"):
                entry.update(cc=geo["cc"], city=geo.get("city", ""))
            self.d_feed.append(entry)
            self.dirty = True
            return True

    def _prune(self, now):
        self.presence = {v: p for v, p in self.presence.items() if now - p["t"] < 120}
        self.last_visit = {v: t for v, t in self.last_visit.items() if now - t < VISIT_GAP}
        self.ip_visits = {i: [t for t in ts if now - t < 3600] for i, ts in self.ip_visits.items()
                          if any(now - t < 3600 for t in ts)}

    def snapshot(self, with_people=False):
        now = time.time()
        with self.lock:
            self._prune(now) if int(now) % 20 == 0 else None
            local = [v for v, p in self.presence.items() if now - p["t"] <= ONLINE_WINDOW]
            live = set(local)
            nodes = 1
            for nid, n in self.view.get("nodes", {}).items():
                if nid != self.iid and now - n.get("ts", 0) < NODE_WINDOW:
                    live.update(n.get("vids", []))
                    nodes += 1
            v = self.view
            day = today()
            days = dict(v.get("days", {}))
            for d, n in self.d_days.items():
                days[d] = days.get(d, 0) + n
            series = []
            for i in range(13, -1, -1):
                d = time.strftime("%Y-%m-%d", time.gmtime(now - i * 86400))
                series.append([d, days.get(d, 0)])
            out = {
                "total": int(v.get("total", 0)) + self.d_total,
                "unique": int(v.get("unique", 0)) + len([x for x in self.d_vids if x not in self.vidset]),
                "today": days.get(day, 0),
                "online": len(live),
                "peak": max(int(v.get("peak", 0)), len(live)),
                "since": v.get("since"),
                "series": series,
                "store": self.mode if self.ok is not False else "local",
                "synced": self.ok, "nodes": nodes,
            }
            if with_people:
                people = []
                for vid in local:
                    g = GEO.lookup(self.presence[vid]["ip"])
                    if g and g.get("lat") is not None:
                        people.append({"cc": g["cc"], "flag": flag(g["cc"]), "city": g["city"],
                                       "lat": g["lat"], "lon": g["lon"]})
                out["visitors"] = people
                feed = list(v.get("feed", [])) + [e for e in self.d_feed if e not in v.get("feed", [])]
                feed = sorted(feed, key=lambda e: e.get("t", 0))[-12:][::-1]
                out["feed"] = [dict(e, flag=flag(e.get("cc", ""))) for e in feed]
            return out


STORE = Store()


# --------------------------------------------------------------- server registry
# Every panel node writes itself into one shared object (panel/servers.json in the
# bucket). All deploys in a project share that bucket, so "Find server" can list
# every *.run.app that was deployed with this panel (same user / path / keys).
HOST_RE = re.compile(r"^[a-z0-9](?:[a-z0-9-]{0,62})(?:\.[a-z0-9-]{1,63})*\.run\.app$")
REG_OBJ = os.environ.get("PANEL_REGISTRY_OBJECT", "panel/servers.json")
REG_KEEP = 30 * 86400


def probe_host(host, timeout=3.0):
    """True when host answers this panel's health endpoint (tests replace this)."""
    try:
        req = urllib.request.Request("https://%s%s/api/health" % (host, BASE), headers={"User-Agent": "saeka-registry"})
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.status == 200 and bool(json.loads(r.read().decode()).get("ok"))
    except Exception:
        return False


class Registry:
    def __init__(self, store):
        self.store = store
        self.lock = threading.Lock()
        self.local = {}            # host -> entry (also the fallback when GCS is unreachable)
        self.registered = 0.0
        self.err = ""
        self.cache = (0.0, None)

    def own_host_ok(self, host):
        host = (host or "").split(":")[0].lower()
        svc = (os.environ.get("K_SERVICE") or "").lower()
        if not HOST_RE.match(host or ""):
            return None
        if svc and not host.startswith(svc + "-"):
            return None            # a spoofed Host header can't add somebody else's name
        return host

    def entry(self, host, info):
        now = int(time.time())
        old = self.local.get(host, {})
        return {"host": host, "service": os.environ.get("K_SERVICE") or host.split("-")[0],
                "region": (info or {}).get("region", ""), "city": (info or {}).get("city", ""),
                "cc": (info or {}).get("cc", ""), "engine": ENGINE, "first": old.get("first", now), "seen": now}

    def register(self, host, info=None, force=False):
        host = self.own_host_ok(host)
        if not host:
            return False
        now = time.time()
        with self.lock:
            if not force and host in self.local and now - self.registered < 300:
                return True
            if self.store.mode == "gcs" and now < self.store.retry_at and host in self.local:
                return True
            e = self.entry(host, info)
            self.local[host] = e
            self.registered = now
        if self.store.mode != "gcs":
            return True
        try:
            for _ in range(6):
                remote, gen = self.store._gcs_get(REG_OBJ)
                servers = dict((remote or {}).get("servers") or {})
                cur = servers.get(host) or {}
                servers[host] = dict(e, first=cur.get("first", e["first"]))
                for h in [h for h, v in servers.items() if now - int(v.get("seen", 0)) > REG_KEEP and h != host]:
                    del servers[h]
                try:
                    self.store._gcs_put({"v": 1, "servers": servers}, gen, REG_OBJ)
                    self.err = ""
                    self.cache = (0.0, None)
                    return True
                except urllib.error.HTTPError as ex:
                    if ex.code != 412:
                        raise
        except Exception as ex:
            self.err = explain_gcs_error(ex)
            with self.lock:
                self.registered = 0.0       # retry on the next request
        return False

    def load(self):
        if self.store.mode == "gcs":
            t, v = self.cache
            if v is not None and time.time() - t < 8:
                return v
            try:
                remote, _ = self.store._gcs_get(REG_OBJ)
                servers = dict((remote or {}).get("servers") or {})
                for h, e in self.local.items():
                    servers.setdefault(h, e)
                self.err = ""
                self.cache = (time.time(), servers)
                return servers
            except Exception as ex:
                self.err = explain_gcs_error(ex)
        return dict(self.local)

    def list(self, current=None, probe=True):
        servers = self.load()
        rows = [dict(v) for v in servers.values() if isinstance(v, dict) and HOST_RE.match(str(v.get("host", "")))]
        cur = (current or "").split(":")[0].lower()
        alive = {}
        if probe:
            def work(h):
                alive[h] = (h == cur) or probe_host(h)
            ts = [threading.Thread(target=work, args=(r["host"],), daemon=True) for r in rows[:30]]
            [t.start() for t in ts]
            [t.join(5) for t in ts]
        for r in rows:
            r["current"] = r["host"] == cur
            r["alive"] = bool(alive.get(r["host"])) if probe else None
            info = region_info(r.get("region"), "registry") if r.get("region") else None
            if info:
                r.update(city=info["city"], country=info["country"], cc=info["cc"], lat=info["lat"], lon=info["lon"],
                         flag=info["flag"])
        rows.sort(key=lambda r: (not r["current"], not r.get("alive"), r.get("service", ""), r["host"]))
        return rows


REGISTRY = Registry(STORE)


# --------------------------------------------------------------------------
# server registry: every panel-deployed *.run.app service registers itself in
# one shared object, so "Find server" can list all of them (same credentials,
# same paths) and the links can be pointed at any one of them.
# --------------------------------------------------------------------------
HOST_RE = re.compile(r"^[a-z0-9](?:[a-z0-9-]{0,62})(?:\.[a-z0-9-]{1,40}){1,2}\.run\.app$")
PEER_URL = os.environ.get("PANEL_PEER_URL", "https://{host}{base}")     # tests point this at 127.0.0.1
REG_STALE = 7 * 86400          # a server that has been down this long is dropped from the list
REG_BEAT = 300                 # own heartbeat interval


def cred_fingerprint(eps):
    """Short hash of the credentials + routes this server accepts. Equal fingerprints = same login works."""
    rows = sorted(json.dumps([e.get("tag"), e.get("path") or e.get("service"), e.get("cred")], sort_keys=True)
                  for e in eps if e.get("cred"))
    return hashlib.sha256("\n".join(rows).encode()).hexdigest()[:10] if rows else ""


class Registry:
    def __init__(self, store):
        self.store = store
        self.lock = threading.RLock()
        self.bucket = os.environ.get("PANEL_REGISTRY_BUCKET", "").strip() or store.bucket
        self.obj = os.environ.get("PANEL_REGISTRY_OBJECT", "panel/servers.json")
        self.file = os.environ.get("PANEL_REGISTRY_FILE", "/tmp/saeka-panel-servers.json")
        self.mode = "gcs" if self.bucket else "local"
        self.self_host = os.environ.get("PANEL_PUBLIC_HOST", "").strip().lower()
        self.err = ""
        self.beat_at = 0.0
        self.checks = {}         # host -> (time, result)

    # ---- storage (GCS object with generation precondition, or a local file)
    def _read(self):
        if self.mode == "gcs":
            url = "%s/storage/v1/b/%s/o/%s?alt=media" % (
                self.store.gcs_base, urllib.parse.quote(self.bucket, safe=""), urllib.parse.quote(self.obj, safe=""))
            try:
                with self.store._gcs_req(url) as r:
                    return json.loads(r.read().decode()), int(r.headers.get("x-goog-generation", "0") or 0)
            except urllib.error.HTTPError as e:
                if e.code == 404:
                    return {}, 0
                raise
        try:
            with open(self.file, "r", encoding="utf-8") as fh:
                return json.load(fh), 0
        except Exception:
            return {}, 0

    def _write(self, data, gen):
        if self.mode == "gcs":
            url = "%s/upload/storage/v1/b/%s/o?uploadType=media&name=%s&ifGenerationMatch=%d" % (
                self.store.gcs_base, urllib.parse.quote(self.bucket, safe=""), urllib.parse.quote(self.obj, safe=""), gen)
            with self.store._gcs_req(url, json.dumps(data).encode(), "application/json"):
                return
        tmp = "%s.%d.%s.tmp" % (self.file, os.getpid(), secrets.token_hex(3))   # unique: never clobbers a parallel writer
        with open(tmp, "w", encoding="utf-8") as fh:
            json.dump(data, fh)
        os.replace(tmp, self.file)

    @staticmethod
    def _norm(d):
        sv = d.get("servers") if isinstance(d, dict) else None
        out = {}
        for h, e in (sv or {}).items():
            if isinstance(e, dict) and HOST_RE.match(str(h)):
                out[h] = e
        return {"v": 1, "servers": out}

    def mutate(self, fn):
        """Read-modify-write with retry on a lost race; returns the stored document."""
        with self.lock:
            for _ in range(8):
                raw, gen = self._read()
                doc = self._norm(raw)
                if fn(doc["servers"]) is False:
                    return doc
                try:
                    self._write(doc, gen)
                    self.err = ""
                    return doc
                except urllib.error.HTTPError as e:
                    if e.code != 412:
                        raise
            raise RuntimeError("registry write kept losing the race")

    def read(self):
        with self.lock:
            return self._norm(self._read()[0])["servers"]

    # ---- own identity
    def note_host(self, host):
        h = (host or "").split(":")[0].strip().lower()
        if not self.self_host and HOST_RE.match(h):
            self.self_host = h
            threading.Thread(target=self.heartbeat, kwargs={"force": True}, daemon=True).start()

    def find_self(self):
        if self.self_host:
            return self.self_host
        svc = os.environ.get("K_SERVICE")
        if svc:
            try:
                num = metadata("project/numeric-project-id", timeout=2.0)
                region = metadata("instance/region", timeout=2.0).rsplit("/", 1)[-1]
                h = "%s-%s.%s.run.app" % (svc.lower(), num, region)
                if HOST_RE.match(h):
                    self.self_host = h
            except Exception as e:
                self.err = "cannot work out this service's URL: %s" % e
        return self.self_host

    def heartbeat(self, force=False):
        host = self.find_self()
        if not host:
            return False
        if not force and time.time() - self.beat_at < REG_BEAT:
            return True
        try:
            eps, _ = load_endpoints()
        except Exception:
            eps = []
        info = Where._from_host(host) or {}
        now = int(time.time())
        mine = {"host": host, "region": info.get("region", ""), "service": os.environ.get("K_SERVICE", ""),
                "engine": ENGINE, "cred": cred_fingerprint(eps), "ts": now, "node": STORE.iid}

        def put(sv):
            old = sv.get(host) or {}
            mine["first"] = old.get("first", now)
            mine["manual"] = False
            sv[host] = dict(old, **mine)
        try:
            self.mutate(put)
            self.beat_at = time.time()
            return True
        except Exception as e:
            self.err = explain_gcs_error(e)
            log("registry heartbeat failed:", self.err)
            return False

    # ---- manual add / forget
    def add(self, host):
        host = (host or "").strip().lower().split("://")[-1].split("/")[0]
        if not HOST_RE.match(host):
            raise ValueError("That is not a Cloud Run host (expected name-123.region.run.app)")
        res = check_peer(host)
        if not res["up"]:
            raise ValueError("%s did not answer as a Saeka panel (%s)" % (host, res["err"] or "no answer"))
        info = Where._from_host(host) or {}

        def put(sv):
            if host not in sv:
                sv[host] = {"host": host, "region": info.get("region", ""), "service": "", "engine": "",
                            "cred": "", "ts": int(time.time()), "first": int(time.time()), "manual": True}
        self.mutate(put)
        self.checks.pop(host, None)

    def forget(self, host):
        host = (host or "").strip().lower()
        if host == self.self_host:
            raise ValueError("This is the server you are on; it cannot be removed")
        def drop(sv):
            if host not in sv:
                return False
            del sv[host]
        self.mutate(drop)
        self.checks.pop(host, None)

    # ---- listing with live health checks
    def _check(self, host):
        c = self.checks.get(host)
        if c and time.time() - c[0] < 15:
            return c[1]
        res = check_peer(host)
        self.checks[host] = (time.time(), res)
        return res

    def listing(self):
        self.heartbeat()
        try:
            sv = self.read()
            err = ""
        except Exception as e:
            sv, err = {}, explain_gcs_error(e)
        me = self.self_host
        if me and me not in sv:
            sv = dict(sv); sv[me] = {"host": me, "ts": int(time.time())}
        hosts = list(sv)
        peers = [h for h in hosts if h != me]
        with ThreadPoolExecutor(max_workers=8) as ex:
            res = dict(zip(peers, ex.map(self._check, peers)))
        eps, _ = load_endpoints()
        mine_fp = cred_fingerprint(eps)
        now = time.time()
        out, dead = [], []
        for h in hosts:
            e = sv[h]
            info = Where._from_host(h) or region_info(e.get("region", ""), "registry") or {}
            r = {"up": True, "ms": 0, "err": ""} if h == me else res[h]
            fp = e.get("cred", "")
            if not r["up"] and now - e.get("ts", now) > REG_STALE and h != me:
                dead.append(h)
            out.append({"host": h, "self": h == me, "up": r["up"], "ms": r["ms"], "err": r["err"],
                        "region": info.get("region", ""), "city": info.get("city", ""), "country": info.get("country", ""),
                        "cc": info.get("cc", ""), "service": e.get("service", ""), "engine": e.get("engine", ""),
                        "seen": int(e.get("ts", 0)), "manual": bool(e.get("manual")),
                        "same_login": (not fp or not mine_fp or fp == mine_fp)})
        if dead:
            def drop(s):
                for h in dead:
                    s.pop(h, None)
            try:
                self.mutate(drop)
            except Exception:
                pass
            out = [o for o in out if o["host"] not in dead]
        out.sort(key=lambda o: (not o["self"], not o["up"], o["region"], o["host"]))
        return {"self": me, "servers": out, "store": self.mode, "error": err or self.err}


def check_peer(host, timeout=4.0):
    """Health-check another panel. Only hosts that passed HOST_RE ever get here."""
    t0 = time.time()
    last = {"up": False, "ms": None, "err": "no answer"}
    for base in (BASE, LEGACY_BASE):         # servers deployed before the move still answer on the old path
        url = PEER_URL.format(host=host, base=base) + "/api/health"
        try:
            req = urllib.request.Request(url, headers={"User-Agent": "saeka-panel/registry"})
            with urllib.request.urlopen(req, timeout=timeout) as r:
                d = json.loads(r.read(4096).decode("utf-8", "replace"))
            if isinstance(d, dict) and d.get("ok") is True and d.get("panel") == "saeka":
                return {"up": True, "ms": int((time.time() - t0) * 1000), "err": ""}
            last = {"up": False, "ms": None, "err": "not a Saeka panel"}
        except urllib.error.HTTPError as e:
            last = {"up": False, "ms": None, "err": "HTTP %d" % e.code}
        except Exception as e:
            last = {"up": False, "ms": None, "err": "no answer (%s)" % type(e).__name__}
            break                              # host unreachable: the second path would fail the same way
    return last


REGISTRY = Registry(STORE)


# --------------------------------------------------------------------------
# auth
# --------------------------------------------------------------------------
PANEL_KEY = os.environ.get("PANEL_KEY", "").strip()
if not PANEL_KEY:
    PANEL_KEY = secrets.token_urlsafe(9)
    log("PANEL_KEY was not set - generated one for this instance: %s" % PANEL_KEY)
    log("(set PANEL_KEY at deploy time so every Cloud Run instance shares it)")
SECRET = hashlib.sha256(b"saeka-panel/v1:" + PANEL_KEY.encode()).digest()
_fails = deque(maxlen=200)
_rl = {}
_rl_lock = threading.Lock()


def make_session():
    exp = str(int(time.time()) + SESSION_TTL)
    return exp + "." + hmac.new(SECRET, exp.encode(), hashlib.sha256).hexdigest()


def valid_session(tok):
    try:
        exp, sig = tok.split(".", 1)
        good = hmac.new(SECRET, exp.encode(), hashlib.sha256).hexdigest()
        return hmac.compare_digest(sig, good) and int(exp) > time.time()
    except Exception:
        return False


def allow(key, limit, per):
    now = time.time()
    with _rl_lock:
        q = [t for t in _rl.get(key, []) if now - t < per]
        if len(q) >= limit:
            _rl[key] = q
            return False
        q.append(now)
        _rl[key] = q
        if len(_rl) > 5000:
            for k in [k for k, v in _rl.items() if not v or now - v[-1] > 600]:
                _rl.pop(k, None)
        return True


# --------------------------------------------------------------------------
# http
# --------------------------------------------------------------------------
def load_index():
    try:
        with open(INDEX_FILE, "rb") as fh:
            raw = fh.read()
    except OSError:
        raw = b"<!doctype html><title>Panel</title><p>panel/index.html is missing from this image."
    return raw, gzip.compress(raw, 9)


INDEX_RAW, INDEX_GZ = load_index()
CSP = ("default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; font-src data:; "
       "img-src 'self' data: https://flagcdn.com; connect-src 'self' wss: ws:; base-uri 'none'; "
       "form-action 'none'; frame-ancestors 'none'")
SEC = {"X-Content-Type-Options": "nosniff", "Referrer-Policy": "no-referrer",
       "X-Frame-Options": "DENY", "Cross-Origin-Opener-Policy": "same-origin"}


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    timeout = 20
    server_version = "panel"
    sys_version = ""

    def log_message(self, fmt, *args):
        pass

    # ---- helpers
    def _send(self, code, body, ctype, extra=None):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        for k, v in SEC.items():
            self.send_header(k, v)
        for k, v in (extra or {}).items():
            self.send_header(k, v)
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def _json(self, code, obj, extra=None):
        self._send(code, json.dumps(obj, separators=(",", ":")).encode(), "application/json; charset=utf-8", extra)

    def _ip(self):
        xff = (self.headers.get("X-Panel-Xff") or "") + "," + (self.headers.get("X-Forwarded-For") or "")
        for part in xff.split(","):
            part = part.strip()
            if is_public_ip(part):
                return part
        return self.client_address[0]

    def _host(self):
        return (self.headers.get("X-Forwarded-Host") or self.headers.get("Host") or "").split(",")[0].strip()

    def _authed(self):
        for part in (self.headers.get("Cookie") or "").split(";"):
            k, _, v = part.strip().partition("=")
            if k == "sp_s":
                return valid_session(v)
        return False

    def _body(self):
        try:
            n = int(self.headers.get("Content-Length") or 0)
        except ValueError:
            n = -1
        if n < 0 or n > 4096:
            return None
        raw = self.rfile.read(n) if n else b"{}"
        try:
            d = json.loads(raw.decode() or "{}")
            return d if isinstance(d, dict) else None
        except Exception:
            return None

    def _route(self):
        p = urllib.parse.urlsplit(self.path).path
        if p == LEGACY_BASE or p.startswith(LEGACY_BASE + "/"):
            p = p[len(LEGACY_BASE):] or "/"
        p = p.rstrip("/") or "/"
        if p in ("/", "/health") or p.startswith("/api/"):
            return p
        return None

    # ---- verbs
    def do_HEAD(self):
        self.do_GET()

    def do_GET(self):
        r = self._route()
        if r is None:
            return self._send(404, b"404 Not Found", "text/plain; charset=utf-8")
        if r == "/health":
            return self._send(200, b"OK", "text/plain; charset=utf-8")
        if r == "/":
            ae = self.headers.get("Accept-Encoding", "")
            if "gzip" in ae:
                return self._send(200, INDEX_GZ, "text/html; charset=utf-8",
                                  {"Content-Encoding": "gzip", "Vary": "Accept-Encoding", "Content-Security-Policy": CSP})
            return self._send(200, INDEX_RAW, "text/html; charset=utf-8", {"Content-Security-Policy": CSP})
        if r == "/api/health":
            return self._json(200, {"ok": True, "panel": "saeka", "up": int(time.time() - STARTED)})
        if r == "/api/public":
            REGISTRY.register(self._host(), WHERE.get(self._host())[0])
            return self._json(200, self._public())
        if r == "/api/servers":
            if not self._authed():
                return self._json(401, {"ok": False, "error": "locked"})
            REGISTRY.register(self._host(), WHERE.get(self._host())[0])
            rows = REGISTRY.list(self._host(), probe=True)
            return self._json(200, {"ok": True, "servers": rows, "store": STORE.mode, "error": REGISTRY.err,
                                    "users": ssh_users()})
        if r == "/api/server":
            if not self._authed():
                return self._json(401, {"ok": False, "error": "locked"})
            return self._json(200, self._full())
        if r == "/api/servers":
            if not self._authed():
                return self._json(401, {"ok": False, "error": "locked"})
            if not allow(("srv", self._ip()), 30, 60):
                return self._json(429, {"ok": False})
            REGISTRY.note_host(self._host())
            try:
                return self._json(200, dict(REGISTRY.listing(), ok=True))
            except Exception as e:
                return self._json(500, {"ok": False, "error": explain_gcs_error(e)})
        self._json(404, {"ok": False})

    def do_POST(self):
        r = self._route()
        if r is None:
            return self._json(404, {"ok": False})
        if self.headers.get("X-Panel") != "1":
            return self._json(403, {"ok": False})
        body = self._body()
        if body is None:
            return self._json(400, {"ok": False})
        ip = self._ip()
        if r == "/api/pulse":
            if not allow(("pulse", ip), 120, 60):
                return self._json(429, {"ok": False})
            vid = str(body.get("vid", ""))
            if not re.fullmatch(r"[a-f0-9]{12,32}", vid):
                return self._json(400, {"ok": False})
            authed = self._authed()
            REGISTRY.note_host(self._host())
            geo = GEO.lookup(ip, block=bool(body.get("nv")))
            STORE.pulse(vid, ip, bool(body.get("nv")), geo)
            REGISTRY.register(self._host(), WHERE.get(self._host())[0])
            return self._json(200, self._public(authed))
        if r == "/api/login":
            now = time.time()
            recent = [t for t in _fails if now - t < 60]
            if len(recent) >= 40 or not allow(("login", ip), 6, 60):
                return self._json(429, {"ok": False, "error": "slow down"}, {"Retry-After": "30"})
            key = str(body.get("key", ""))
            if hmac.compare_digest(hashlib.sha256(key.encode()).digest(),
                                   hashlib.sha256(PANEL_KEY.encode()).digest()):
                secure = "; Secure" if self.headers.get("X-Forwarded-Proto", "https") == "https" else ""
                cookie = "sp_s=%s; HttpOnly; SameSite=Strict; Path=/; Max-Age=%d%s" % (
                    make_session(), SESSION_TTL, secure)
                return self._json(200, {"ok": True}, {"Set-Cookie": cookie})
            _fails.append(now)
            time.sleep(0.6)
            return self._json(401, {"ok": False, "error": "wrong key"})
        if r in ("/api/servers/add", "/api/servers/forget"):
            if not self._authed():
                return self._json(401, {"ok": False, "error": "locked"})
            if not allow(("srv", ip), 30, 60):
                return self._json(429, {"ok": False})
            REGISTRY.note_host(self._host())
            try:
                (REGISTRY.add if r.endswith("add") else REGISTRY.forget)(str(body.get("host", "")))
            except ValueError as e:
                return self._json(400, {"ok": False, "error": str(e)})
            except Exception as e:
                return self._json(500, {"ok": False, "error": explain_gcs_error(e)})
            return self._json(200, dict(REGISTRY.listing(), ok=True))
        if r == "/api/logout":
            return self._json(200, {"ok": True}, {
                "Set-Cookie": "sp_s=; HttpOnly; SameSite=Strict; Path=/; Max-Age=0"})
        self._json(404, {"ok": False})

    # ---- payloads
    def _server_block(self, full):
        info, provider = WHERE.get(self._host())
        s = dict(info) if info else {"region": "unknown", "city": "Unknown", "country": "", "cc": "",
                                     "flag": flag(""), "lat": None, "lon": None, "source": "none"}
        s["provider"] = provider
        s["host"] = self._host()
        if full:
            s.update(service=os.environ.get("K_SERVICE"), revision=os.environ.get("K_REVISION"),
                     engine=ENGINE, ads_mode=os.environ.get("ADS_MODE", ""), node=STORE.iid,
                     uptime_s=int(time.time() - STARTED),
                     store_error=STORE.err)    # authed only: names what GCS refused
        return s

    def _public(self, authed=None):
        authed = self._authed() if authed is None else authed
        d = {"ok": True, "authed": authed, "now": int(time.time() * 1000),
             "server": self._server_block(False), "stats": STORE.snapshot(with_people=authed)}
        return d

    def _full(self):
        try:
            eps, mtime = load_endpoints()
            err = ""
        except Exception as e:
            eps, mtime, err = [], None, "%s: %s" % (type(e).__name__, e)
        probe_all(eps)
        d = self._public(True)
        d["server"] = self._server_block(True)
        d["endpoints"] = eps
        d["ssh_users"] = ssh_users()
        d["config"] = {"path": XRAY_CONFIG, "mtime": mtime, "error": err, "count": len(eps),
                       "up": sum(1 for e in eps if e.get("up")),
                       "supported": sum(1 for e in eps if e.get("supported", True))}
        return d


class Server(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True
    request_queue_size = 64


def flusher():
    last = 0.0
    while True:
        time.sleep(2)
        try:
            if time.time() < STORE.retry_at:
                continue
            if STORE.dirty or time.time() - last > 20:
                STORE.flush()
                last = time.time()
        except Exception as e:     # never let this thread die
            log("flusher:", e)


def warmup():
    try:
        WHERE.get()
        load_endpoints()
    except Exception as e:
        log("warmup:", e)
    beat(first=True)


def beat(first=False):
    """Register this service in the shared registry (creates it if nobody has yet)."""
    try:
        if REGISTRY.heartbeat(force=True):
            if first:
                log("registered in the server registry as %s (%s)" % (REGISTRY.self_host, REGISTRY.mode))
        elif first:
            log("registry: own URL not known yet - will register on the first panel visit")
    except Exception as e:
        log("registry:", e)


def registry_loop():
    while True:
        time.sleep(REG_BEAT)
        beat()


def main():
    srv = Server((BIND, PORT), Handler)

    def stop(*_):
        log("shutting down, flushing counters")
        try:
            STORE.flush()
        finally:
            os._exit(0)

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    threading.Thread(target=flusher, daemon=True).start()
    threading.Thread(target=warmup, daemon=True).start()
    threading.Thread(target=registry_loop, daemon=True).start()
    log("listening on %s:%d  engine=%s  store=%s  index=%d bytes" % (
        BIND, PORT, ENGINE, STORE.mode, len(INDEX_RAW)))
    srv.serve_forever(poll_interval=0.5)


if __name__ == "__main__":
    main()
