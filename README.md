
## Raw TCP companion VM

Cloud Run cannot expose the raw TCP/UDP handshake required by VLESS+REALITY,
OpenVPN, or SSH. The supported deployment is therefore hybrid:

- `deploy.sh` continues to deploy the HTTP-compatible transports to Cloud Run:
  WebSocket, HTTPUpgrade, XHTTP and gRPC.
- `deploy_vm.py` provisions a separate Debian 12 Compute Engine VM with a
  regional static IP for REALITY, OpenVPN and a restricted SSH SOCKS tunnel.
- If a domain and a least-privilege Cloudflare DNS token are supplied, the
  script creates a sibling A record such as `vpn.example.com` pointing at the
  VM. It never attempts to modify or repoint `*.run.app`.

Run it after the Cloud Run deployment:

```bash
chmod +x deploy_vm.py
python3 deploy_vm.py
```

The script stores generated artifacts under `~/.deploy_vm/`:

- `*-startup.sh` — the exact VM startup script for audit/recovery
- `*-client1.ovpn` — the OpenVPN client profile (mode 0600)
- `*_tunnel_key` — the SSH forwarding-only key (mode 0600)

### Endpoint selection

Use the Cloud Run host for the existing HTTP transports. Use the VM hostname or
static IP for REALITY, OpenVPN and SSH. A VM IP cannot be pointed *to* a
`run.app` hostname: DNS records point names to addresses, while Cloud Run does
not provide a raw TCP forwarding layer. The deployer prints separate endpoints
and client material so a frontend can present these as distinct proxy choices.

The VM firewall opens only the selected protocol ports plus the IAP SSH range.
The SSH account is forwarding-only and has no interactive shell. Keep the
printed REALITY link, OpenVPN profile and SSH private key secret.
