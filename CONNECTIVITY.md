# Connectivity notes

**Panel.** Every engine (Xray engines, SSH Gateway, OVPN Relay, REALITY Combo) serves the panel at the
service root, so opening the run.app URL in a browser shows it. Tunnel paths are unchanged.

**Xray policy.** `common/config-*.json` now set `policy.levels.0` (`connIdle 3600`, `handshake 8`,
`uplinkOnly 30`, `downlinkOnly 60`). Xray's default drops any connection idle for 300 s and cuts a
half-closed one after 2-5 s. Egress resolves IPv4 only (Cloud Run has no IPv6 egress) and uses TCP keepalives.
Clients should also raise their own idle policy; Xray clients default to 300 s too.

**SSH / OVPN bridge.** `proxies/common/ws_bridge.py` was broken (it read from a writer object, so every
connection was reset). Fixed, plus: keepalive after 30 s, three upstream connect attempts, payload sent
in the same segment as the headers is forwarded, and a half-closed session is closed after 10 s.

**Google Cloud CDN (no third party).** In `deploy.sh`'s load balancer step, type `AUTO` for a Google-only
setup with no domain: a global IP, `<ip>.sslip.io`, a Google-managed certificate (15-60 min) plus an instant
self-signed one, HTTP/3 (QUIC) and Cloud CDN on the backend. The CDN runs in `USE_ORIGIN_HEADERS` mode and
tunnel/panel responses carry no cache headers, so nothing is cached; what you gain is Google's nearest edge
and backbone. `GCP_CDN=0 ./deploy.sh` leaves Cloud CDN off. The panel then lists **GCP CDN** under Address
and SNI. The load balancer adds a monthly forwarding-rule cost. Not exercised here (no GCP access).

**Limits that no setting removes.** Cloud Run ends any request after 3600 s, so a single connection lasts
at most one hour; clients must reconnect. XHTTP `packet-up` sends separate POSTs, which only work when they
land on the same instance (use `stream-up` / `stream-one`, or `--max-instances 1`).
