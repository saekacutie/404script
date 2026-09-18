# ch-saeka (v2 - per-engine)

## What changed from v1

**v1** had one `Dockerfile` that installed *all six* proxy engines
(HAProxy, Envoy, Caddy, Traefik, H2O-built-from-source, OpenResty) into a
single Ubuntu image, then picked one at *container start* via
`PROXY_ENGINE`. That meant every build paid for H2O's from-source
`cmake`/`ninja` compile and every other engine's install, even though a
given deployment only ever runs one of them.

**v2** gives each engine its own folder under `proxies/<engine>/` with
its own `Dockerfile`, own config, own `entrypoint.sh`. Picking HAProxy in
`deploy.sh` now builds *only* `proxies/haproxy/Dockerfile` - a small
Alpine image with HAProxy + Xray and nothing else. None of the other
five engines are downloaded, compiled, or added to the image.

```
common/                  shared by every engine
  config-ads.json         Xray inbound config, ads allowed
  config-noads.json        "        "        , ad/tracker domains blackholed
  index.html               plain 404 landing page (served where an engine has a static fallback)
proxies/
  haproxy/  Dockerfile  haproxy.cfg   entrypoint.sh
  envoy/    Dockerfile  envoy.yaml    entrypoint.sh
  caddy/    Dockerfile  Caddyfile     entrypoint.sh
  h2o/      Dockerfile  h2o.conf      entrypoint.sh
  traefik/  Dockerfile  traefik.yml  dynamic.yml  entrypoint.sh
  openresty/Dockerfile  nginx.conf    entrypoint.sh
deploy.sh                 interactive deployer (password-gated, streams real build/deploy logs)
regions.sh                 region picker, sourced by deploy.sh
generate-client-links.sh  builds vless/trojan share links + outbound JSON for a deployed host
gh_verify.py               generic multi-format syntax linter for this repo (yaml/json/py/sh/docker/haproxy/nginx/envoy)
```

## Base images (no Ubuntu, per your request)

| Engine     | Base                              |
|------------|------------------------------------|
| HAProxy    | `haproxy:2.9-alpine`               |
| Caddy      | `caddy:2-alpine`                   |
| Traefik    | `traefik:v3.1` (alpine-based)      |
| OpenResty  | `openresty/openresty:1.25.3.1-alpine` |
| H2O        | `alpine:3.20` + `apk add h2o`      |
| Envoy      | `debian:bookworm-slim` + apt.envoyproxy.io (Envoy's binary needs glibc, so it can't run on musl/Alpine - this is the one engine that isn't Alpine, but it's Debian-slim, not Ubuntu) |

Xray-core is fetched once per engine from its GitHub release zip (small,
statically-linked Go binary - works on both the Alpine and Debian bases
above).

## Deploying

```
./deploy.sh
```

You'll be asked for the deployer password first (see below), then
engine, ads mode, region, service name, and sizing tier - same flow as
v1. Build and deploy output now streams to your terminal as it happens
(`tee`'d to `build.log`/`deploy.log`, which are only kept around if a
step fails, for troubleshooting).


### Building one engine directly (without the interactive script)

```
docker build -f proxies/haproxy/Dockerfile -t my-haproxy-image .
```

Build context is the repo root (so `common/` and the chosen
`proxies/<engine>/` are both reachable) - just swap the `-f` path and
image tag for a different engine.

## Anti-abuse / rate limiting

Basic per-IP connection and request-rate limiting is wired into the two
engines whose config format supports it simply: HAProxy (stick-table,
`too_many_conns` / `conn_rate_abuse` / `req_rate_abuse` ACLs, 429 on
trip) and OpenResty (`limit_conn_zone` / `limit_req_zone`). This blunts
casual abusive traffic from a single source; it isn't a substitute for
network-level DDoS protection (e.g. Cloud Armor in front of Cloud Run).
Ask if you want the same style of limiting added to Envoy/Caddy/Traefik/H2O.
