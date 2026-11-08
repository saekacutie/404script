# Saeka panel

Web control panel served by every Xray engine (HAProxy, Envoy, Caddy, H2O, Traefik, OpenResty) at

    https://<your-service>/saeka-panel

`/` keeps its 404 decoy; the panel lives on its own path and runs as a **separate process**
(`python3 /opt/panel/server.py`, 127.0.0.1:10030, stdlib only). If it ever crashes the entrypoint
restarts it on its own and proxy traffic is not touched.

## What it shows
* **Region** - detected live: Cloud Run/GCE metadata server, then the `*.REGION.run.app` hostname,
  then GeoIP of the egress IP. Shown as code + emoji flag + a globe with a pin on the server.
* **Visitors** - online now, total, today, unique. Counted from real browsers (JS pulse), once per
  browser per 30 minutes. Totals live in a Cloud Storage object (`PANEL_BUCKET`, created by
  `deploy.sh`) with optimistic concurrency, so all Cloud Run instances share one number and it
  survives restarts. Without a bucket it falls back to a per-instance file and says so in the UI.
* **After unlock (access key)** - credentials read live from `/etc/xray/config.json`, share links
  (VLESS / VMess / Trojan / Shadowsocks, WS / HTTPUpgrade / XHTTP / gRPC / H2) with copy + QR,
  per-inbound TCP health, a real WebSocket handshake test through the public edge, visitor
  locations on the globe and a recent-visit feed.

## Settings (environment variables)
| var | meaning |
| --- | --- |
| `PANEL_KEY` | access key (deploy.sh generates one and prints it; set it explicitly so every instance shares it) |
| `PANEL_BUCKET` | GCS bucket for the shared counter |
| `PANEL_REGION` | force a region id, e.g. `asia-southeast1` |
| `PANEL_GEOIP=0` | disable visitor/egress GeoIP lookups (ip-api.com) |
| `PANEL_ENGINE` | set by each Dockerfile; marks gRPC/H2 as unsupported on OpenResty |

Visitor IPs are never stored; only country + city of the last 20 visits.

## Develop
    python3 panel/build.py        # src/ + vendor/ -> panel/index.html (self-contained, no CDN)
    python3 panel/test_panel.py   # unit tests incl. a fake-GCS multi-node counter test
    PANEL_KEY=dev XRAY_CONFIG=common/config-noads.json python3 panel/server.py   # http://127.0.0.1:10030/saeka-panel

Vendored: QR generator (Kazuhiko Arase, MIT); fonts Big Shoulders Display, Hanken Grotesk,
JetBrains Mono (SIL OFL); land mask derived from Natural Earth (public domain).
