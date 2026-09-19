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
| `proxies/caddy/Caddyfile`, `h2o/h2o.conf`, `envoy/envoy.yaml`, `haproxy/haproxy.cfg`, `nginx/nginx.conf`, `traefik/dynamic.yml` | new `/saeka-ssh` route -> `127.0.0.1:10016` (HTTP/1.1 + Upgrade) |
| `haproxy.cfg`, `nginx.conf` | per-IP rate limits (the source of the 429s) removed |
| `traefik/Dockerfile` | adds the three lines below |

## Dockerfile change (identical for every engine)
Add this in the final stage, as root, before the `COPY ... entrypoint.sh` line:
```dockerfile
COPY common/ssh-install.sh /tmp/ssh-install.sh
COPY common/ssh-ws.sh /usr/local/bin/ssh-ws.sh
RUN sh /tmp/ssh-install.sh && rm -f /tmp/ssh-install.sh && chmod +x /usr/local/bin/ssh-ws.sh
```
(Only the traefik Dockerfile was available, so it is the only one included; add the lines above to the other five.)

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
