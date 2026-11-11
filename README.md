xx:me

## Tunnel engines (menu 7, 8, 9)

| # | Engine | What it builds |
|---|--------|----------------|
| 7 | SSH | `/saeka-ssh` (Dropbear + UDPGW). Optional OpenVPN: answer `y` and a VM is created for you; `/saeka-ovpn` then relays to it. |
| 8 | OVPN | Cloud Run first, then an auto-created VM running OpenVPN (TCP 1194). `/saeka-ovpn` relays to the VM, `/cert` serves the `.ovpn` profile (login = the user you create). |
| 9 | REALITY | Cloud Run first, then an auto-created VM running Xray VLESS+REALITY (`/saeka-tcp`), optional OpenVPN on the same VM, SSH on Cloud Run. |

The VM is created by `deploy_vm.py --auto` (static IP, firewall, Compute API, config) and its result is read back
through GCE guest attributes, so no SSH/IAP access is needed. After the Cloud Run deploy the script performs a real
HTTP-Upgrade handshake against every tunnel path and prints the container log if one does not answer `101`.

Optional Google Cloud CDN: the load-balancer step at the end of `deploy.sh` (works for every engine) turns on
Cloud CDN for the backend with `USE_ORIGIN_HEADERS`, so tunnels and APIs are never cached.

Tests: `python3 -I proxies/test_bridge.py` (tunnel bridge), `python3 -I panel/test_panel.py` (panel).
