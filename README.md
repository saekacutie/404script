xx:me

Deployer for Cloud Run proxy engines. See `panel/README.md` for the web panel (`/saeka-panel`).

## CDN and long-lived xHTTP connections

Works behind a proxying CDN (Cloudflare, Cloud CDN, ...) and keeps idle tunnels
open:

- **Server keepalive.** Every xHTTP inbound sets `scStreamUpServerSecs: "10-25"`,
  so a stream-up upload sends a keepalive at least every 25s - under the
  30-60s idle limits common on CDNs and proxies (Xray's default is 20-80s).
- **Proxy timeouts.** Each engine is configured not to cut a quiet tunnel:
  OpenResty raises the body/send timeouts and lifts the 1m body cap on xHTTP
  routes (stream-up uploads are chunked and unbounded), Caddy never buffers
  xHTTP, H2O's 30s I/O and 5min WebSocket timeouts are raised to 1h. Envoy (no
  timeouts) and HAProxy (1h) were already fine; Traefik was tested and needed
  no change.
- **Hard cap.** Cloud Run ends any single request at 3600s. The generated
  xHTTP client configs use `xmux.hMaxReusableSecs: 1800-3000` so connections are
  retired and replaced before that.
- **Client side.** `./generate-client-links.sh <host>` now emits an xHTTP link and
  outbound JSON for each protocol (mode `packet-up`, the one every CDN carries).
  For a CDN, dial the edge but keep SNI/Host on your domain:

  ```
  CDN_ADDRESS=<edge ip or CDN-fronted domain> ./generate-client-links.sh <host> [port]
  XHTTP_MODE=stream-up ...   # only if your CDN streams request bodies
  ```

  On Cloudflare: proxy the record (orange cloud), SSL/TLS mode **Full**, and
  keep caching off for these paths. Cloudflare returns a 524 if the origin sends
  nothing for 100s, so don't rely on a completely silent connection there.

