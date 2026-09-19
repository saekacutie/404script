# SSH over WebSocket (`/saeka-ssh`, default login `saeka:saeka`)

```
client ──WS /saeka-ssh──▶ proxy engine :8080 ──▶ xray dokodemo-door 127.0.0.1:10016 ──▶ dropbear 127.0.0.1:2222
```

## Files
| Path | What changed |
|---|---|
| `common/ssh-install.sh` | **new** – build-time install of dropbear (Alpine or Debian/Ubuntu) |
| `common/ssh-ws.sh` | **new** – runtime: creates the user, writes the WS bridge config, starts + watchdogs dropbear and the bridge |
| `proxies/*/entrypoint.sh` | now `source` ssh-ws.sh, start SSH-WS, trap it on shutdown, watchdog it |
| `proxies/caddy/Caddyfile`, `h2o/h2o.conf`, `envoy/envoy.yaml`, `haproxy/haproxy.cfg`, `openresty/nginx.conf`, `traefik/dynamic.yml` | new `/saeka-ssh` route -> `127.0.0.1:10016` (HTTP/1.1 + Upgrade) |
| `haproxy.cfg`, `openresty/nginx.conf` | per-IP rate limits (the source of the 429s) removed |
| `proxies/*/Dockerfile` (all six) | rebuilt from the README's base-image table, each adding the three `ssh-install.sh` / `ssh-ws.sh` lines below |
| `common/index.html` | plain 404 page (referenced by the h2o and openresty Dockerfiles; not otherwise touched) |

All six `proxies/<engine>/Dockerfile` are included and build against exactly
the bases the README table specifies (`haproxy:2.9-alpine`, `caddy:2-alpine`,
`traefik:v3.1`, `openresty/openresty:1.25.3.1-alpine`, `alpine:3.20 + apk add
h2o`, `debian:bookworm-slim` + apt.envoyproxy.io for Envoy). The nginx engine's
folder is `proxies/openresty/` to match `deploy.sh`'s `PROXY_ENV=openresty`
and the README's own layout table - the previous `proxies/nginx/` name would
not have matched what `deploy.sh` looks for.

**Not included:** `common/config-ads.json` and `common/config-noads.json` -
your Xray inbound configs - weren't in the files you gave me. Every
Dockerfile still `COPY`s them from `common/`, so drop your existing copies
into `common/` before building; nothing here needed to touch them.

## Dockerfile change (identical for every engine)
Each Dockerfile adds this in its final stage, as root, before `COPY ...
entrypoint.sh`:
```dockerfile
COPY common/ssh-install.sh /tmp/ssh-install.sh
COPY common/ssh-ws.sh /usr/local/bin/ssh-ws.sh
RUN sh /tmp/ssh-install.sh && rm -f /tmp/ssh-install.sh && chmod +x /usr/local/bin/ssh-ws.sh
```
(Envoy's Dockerfile runs this with `bash` instead of `sh`, matching the
`bash`-only base it already required.)

## Env vars (optional)
`SSH_USER` (default `saeka`), `SSH_PASS` (default `saeka`), `SSH_ENABLE=0` to disable.
Change the password without rebuilding: `gcloud run services update SVC --set-env-vars SSH_PASS=...`

## Client
```bash
# SOCKS5 on 127.0.0.1:1080 (needs websocat)
ssh -N -D 1080 -o StrictHostKeyChecking=no \
    -o ProxyCommand='websocat --binary asyncstdio: wss://YOUR-SERVICE.run.app/saeka-ssh' \
    saeka@localhost
```
HTTP-injector style apps: SSH host = your run.app host, port 443, TLS on, SNI = same host,
WebSocket path `/saeka-ssh`, user/pass `saeka` / `saeka`.

The account's shell is `/bin/false`: forwarding works, interactive shells / remote commands do not.
