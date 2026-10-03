# 404script — Multi-Proxy Deploy Framework

A framework for deploying and verifying multi-protocol proxy stacks
(Trojan / VMess / VLESS / Shadowsocks across several front proxies).

## Layout

| Path | Purpose |
|---|---|
| `deploy.sh` | Main deploy orchestrator |
| `deploy_vm.py` | VM provisioning helper |
| `generate-client-links.sh` | Builds client share-links from the deployment |
| `gh_verify.py` | Self-verifier: syntax-checks and cross-validates the repo |
| `ws_bridge.py` | WS→TCP bridge (root) |
| `common/` | Shared pieces: `ws_bridge.py`, `cert_server.py`, `config-ads.json`, `config-noads.json`, decoy `index.html` |
| `proxies/` | Per-front-proxy configs: `caddy`, `nginx`, `haproxy`, `traefik`, `envoy`, `h2o`, `openresty`, `reality`, `ssh`, `ovpn-relay` (+ `common`) |
| `tools/deploy_extras.sh` | Extra setup steps |
| `regions.sh` | Region presets |
| `requirements.txt` | Python deps (`websockets>=13`) |

## Usage

```bash
chmod +x deploy.sh
./deploy.sh
# verify the repo any time:
python3 gh_verify.py
```

## Configs

- `common/config-noads.json` / `common/config-ads.json` — 20-inbound Xray configs
  (ports 10000–10019) with and without the ad-blocking variant.

## Security notes

- Review `deploy.sh` before running — it provisions cloud resources.
- Client links contain credentials; don't share them publicly.
