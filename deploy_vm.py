#!/usr/bin/env python3
"""Provision the raw-TCP companion VM for the Cloud Run deployment.
Cloud Run remains the HTTP frontend for WebSocket, HTTPUpgrade, XHTTP and gRPC.
This script provisions a separate Compute Engine VM for protocols that require
an internet-facing TCP/UDP socket: VLESS+REALITY, OpenVPN and SSH SOCKS.
It deliberately never attempts to repoint a *.run.app hostname.
Requirements: Python 3, gcloud authenticated, and an active GCP project.
Optional DNS: set CF_API_TOKEN and pass a domain when prompted. The token must
only have Cloudflare Zone DNS Edit permission.
"""
from __future__ import annotations
import getpass
import json
import os
import secrets
import shlex
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

BOLD = "\033[1m"; RESET = "\033[0m"
GREEN = "\033[1;32m"; RED = "\033[1;31m"; CYAN = "\033[1;36m"
YELLOW = "\033[1;33m"

WORKDIR = Path.home() / ".deploy_vm"

def colour(text: str, code: str) -> str:
    return f"{code}{text}{RESET}"

def die(message: str) -> None:
    print(colour(f"ERROR: {message}", RED), file=sys.stderr)
    raise SystemExit(1)

def cmd(args: list[str], *, check: bool = True, capture: bool = False) -> subprocess.CompletedProcess[str]:
    try:
        result = subprocess.run(args, check=False, capture_output=capture, text=True)
    except FileNotFoundError:
        die(f"{args[0]} is not installed or is not on PATH")
    if check and result.returncode:
        if result.stderr:
            print(result.stderr, file=sys.stderr)
        die(f"command failed: {' '.join(args)}")
    return result

def gcloud_json(args: list[str]) -> dict | None:
    result = cmd(["gcloud", *args, "--format=json"], capture=True, check=False)
    if result.returncode:
        return None
    try:
        value = json.loads(result.stdout)
        return value if isinstance(value, dict) else None
    except json.JSONDecodeError:
        return None

def ask(label: str, default: str | None = None) -> str:
    suffix = f" [{default}]" if default is not None else ""
    value = input(colour(f"  {label}{suffix}: ", CYAN)).strip()
    return value or (default or "")

def ask_yes_no(label: str, default: bool = True) -> bool:
    answer = input(colour(f"  {label} ({'Y/n' if default else 'y/N'}): ", CYAN)).strip().lower()
    return default if not answer else answer.startswith("y")

def project() -> str:
    value = cmd(["gcloud", "config", "get-value", "project"], capture=True).stdout.strip()
    if not value or value == "(unset)":
        die("no active GCP project; run 'gcloud config set project PROJECT_ID'")
    return value

def regional_ip(project_id: str, region: str, name: str) -> str:
    info = gcloud_json(["compute", "addresses", "describe", name, "--region", region, "--project", project_id])
    if not info:
        cmd(["gcloud", "compute", "addresses", "create", name, "--region", region, "--project", project_id])
        info = gcloud_json(["compute", "addresses", "describe", name, "--region", region, "--project", project_id])
    if not info or not info.get("address"):
        die("GCP did not return the reserved address")
    return str(info["address"])

def firewall(project_id: str, name: str, protocol: str, port: int, tag: str, sources: str = "0.0.0.0/0") -> None:
    if gcloud_json(["compute", "firewall-rules", "describe", name, "--project", project_id]):
        return
    cmd(["gcloud", "compute", "firewall-rules", "create", name, "--project", project_id,
         "--direction=INGRESS", "--action=ALLOW", f"--rules={protocol}:{port}",
         f"--source-ranges={sources}", f"--target-tags={tag}"])

def startup(config: dict) -> str:
    # Values are shell-quoted before substitution. The generated script is
    # also saved locally so a failed first boot is reproducible/auditable.
    q = lambda value: shlex.quote(str(value))
    values = {key: q(value) for key, value in config.items()}
    return STARTUP.replace("@@REALITY@@", values["reality"])\
        .replace("@@OVPN@@", values["ovpn"])\
        .replace("@@SSH@@", values["ssh"])\
        .replace("@@RPORT@@", values["reality_port"])\
        .replace("@@DEST@@", values["reality_dest"])\
        .replace("@@SNI@@", values["reality_sni"])\
        .replace("@@OPORT@@", values["ovpn_port"])\
        .replace("@@OPROTO@@", values["ovpn_proto"])\
        .replace("@@PUBKEY@@", values["pubkey"])

def create_vm(project_id: str, zone: str, name: str, machine: str, ip: str, tag: str, script: Path) -> None:
    if gcloud_json(["compute", "instances", "describe", name, "--zone", zone, "--project", project_id]):
        print(colour(f"  Reusing existing VM {name}; delete it for a clean rebuild.", YELLOW))
        return
    cmd(["gcloud", "compute", "instances", "create", name, "--project", project_id,
         "--zone", zone, "--machine-type", machine, "--image-family=debian-12",
         "--image-project=debian-cloud", "--address", ip, "--tags", tag,
         f"--metadata-from-file=startup-script={script}"])

def ssh(project_id: str, zone: str, name: str, remote: str) -> subprocess.CompletedProcess[str]:
    return cmd(["gcloud", "compute", "ssh", name, "--project", project_id, "--zone", zone,
                "--tunnel-through-iap", "--command", remote], capture=True, check=False)

def wait_ready(project_id: str, zone: str, name: str, timeout: int = 900) -> dict:
    end = time.time() + timeout
    while time.time() < end:
        result = ssh(project_id, zone, name, "sudo cat /etc/vm-setup-complete.json 2>/dev/null")
        if result.returncode == 0:
            try:
                data = json.loads(result.stdout.strip())
                if data.get("status") == "ready":
                    return data
            except json.JSONDecodeError:
                pass
        print("\r  Waiting for VM startup configuration...", end="", flush=True)
        time.sleep(10)
    print()
    die(f"VM setup timed out; inspect with: gcloud compute ssh {name} --zone {zone} --tunnel-through-iap")

def scp(project_id: str, zone: str, name: str, remote: str, local: Path) -> bool:
    result = cmd(["gcloud", "compute", "scp", f"{name}:{remote}", str(local),
                  "--project", project_id, "--zone", zone, "--tunnel-through-iap"], check=False)
    return result.returncode == 0

def cloudflare(domain: str, subdomain: str, ip: str, token: str) -> str | None:
    root = ".".join(domain.rstrip(".").split(".")[-2:])
    fqdn = f"{subdomain}.{root}"
    def request(method: str, path: str, payload: dict | None = None) -> dict:
        body = None if payload is None else json.dumps(payload).encode()
        req = urllib.request.Request("https://api.cloudflare.com/client/v4" + path,
            data=body, method=method,
            headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(req, timeout=20) as response:
                return json.loads(response.read())
        except (urllib.error.HTTPError, urllib.error.URLError) as error:
            print(colour(f"Cloudflare request failed: {error}", YELLOW))
            return {}
    zones = request("GET", f"/zones?name={root}")
    if not zones.get("success") or not zones.get("result"):
        return None
    zone = zones["result"][0]["id"]
    records = request("GET", f"/zones/{zone}/dns_records?type=A&name={fqdn}")
    payload = {"type": "A", "name": fqdn, "content": ip, "ttl": 120, "proxied": False}
    if records.get("result"):
        record_id = records["result"][0]["id"]
        result = request("PUT", f"/zones/{zone}/dns_records/{record_id}", payload)
    else:
        result = request("POST", f"/zones/{zone}/dns_records", payload)
    return fqdn if result.get("success") else None

# ------------------------------------------------------------------------------
# STARTUP SCRIPT — Fixed for Xray ≥ 26.3.27: removes legacy config, uses XHTTP
# ------------------------------------------------------------------------------
STARTUP = r'''#!/bin/bash
set -euo pipefail
exec > /var/log/vm-setup.log 2>&1
export DEBIAN_FRONTEND=noninteractive

echo "=== Starting VM provisioning ==="

apt-get update -y
apt-get install -y curl unzip ca-certificates openssl jq

REALITY=@@REALITY@@; OVPN=@@OVPN@@; SSH_TUNNEL=@@SSH@@
RPORT=@@RPORT@@; DEST=@@DEST@@; SNI=@@SNI@@
OPORT=@@OPORT@@; OPROTO=@@OPROTO@@; PUBKEY=@@PUBKEY@@

IFACE=$(ip route | awk '/default/ {print $5; exit}')
IP=$(curl -sf -H 'Metadata-Flavor: Google' http://metadata.google.internal/computeMetadata/v1/instance/network-interfaces/0/access-configs/0/external-ip)

# --------------------------
# CRITICAL: Remove any legacy/incompatible config before Xray starts
# This prevents "HTTP transport removed" crash loop
# --------------------------
rm -f /etc/xray/config.json /usr/local/etc/xray/config.json
mkdir -p /usr/local/etc/xray

REALITY_JSON='{"enabled":false}'; OVPN_JSON='{"enabled":false}'; SSH_JSON='{"enabled":false}'

if [ "$REALITY" = true ]; then
  echo "=== Installing Xray + VLESS+REALITY ==="
  curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh | bash -s -- install

  UUID=$(cat /proc/sys/kernel/random/uuid)
  KEYS=$(/usr/local/bin/xray x25519)
  PRIVATE=$(echo "$KEYS" | awk -F': ' '/Private key/{print $2}')
  PUBLIC=$(echo "$KEYS" | awk -F': ' '/Public key/{print $2}')
  SID=$(openssl rand -hex 8)

  # Clean VLESS+REALITY config — no legacy HTTP transport here
  jq -n \
    --arg uuid "$UUID" \
    --arg private "$PRIVATE" \
    --arg dest "$DEST" \
    --arg sni "$SNI" \
    --arg sid "$SID" \
    --argjson port "$RPORT" \
    '{
      log: {loglevel: "warning"},
      inbounds: [{
        listen: "0.0.0.0",
        port: $port,
        protocol: "vless",
        settings: {
          clients: [{id: $uuid, flow: "xtls-rprx-vision"}],
          decryption: "none"
        },
        streamSettings: {
          network: "tcp",
          security: "reality",
          realitySettings: {
            show: false,
            dest: $dest,
            xver: 0,
            serverNames: [$sni],
            privateKey: $private,
            shortIds: [$sid]
          }
        }
      }],
      outbounds: [{protocol: "freedom"}]
    }' > /usr/local/etc/xray/config.json

  # Symlink so all expected paths get the same clean config
  ln -sf /usr/local/etc/xray/config.json /etc/xray/config.json

  systemctl enable --now xray
  sleep 2

  if systemctl is-active --quiet xray; then
    echo "Xray+REALITY started successfully"
    REALITY_JSON=$(jq -n \
      --arg uuid "$UUID" \
      --arg pbk "$PUBLIC" \
      --arg sid "$SID" \
      --arg sni "$SNI" \
      --arg dest "$DEST" \
      --argjson port "$RPORT" \
      '{enabled:true,uuid:$uuid,publicKey:$pbk,shortId:$sid,serverName:$sni,dest:$dest,port:$port}')
  else
    echo "WARNING: Xray service failed to start"
    systemctl status xray --no-pager || true
  fi
fi

if [ "$OVPN" = true ]; then
  echo "=== Installing OpenVPN ==="
  apt-get install -y openvpn easy-rsa iptables-persistent

  EZ=/etc/openvpn/easy-rsa; mkdir -p "$EZ"; cp -r /usr/share/easy-rsa/* "$EZ"/; cd "$EZ"
  ./easyrsa init-pki
  ./easyrsa --batch build-ca nopass
  ./easyrsa --batch gen-req server nopass
  ./easyrsa --batch sign-req server server
  ./easyrsa --batch gen-req client1 nopass
  ./easyrsa --batch sign-req client client1
  ./easyrsa gen-dh
  openvpn --genkey tls-crypt "$EZ/tc.key"

  mkdir -p /etc/openvpn/server
  cat > /etc/openvpn/server/server.conf <<EOF
port $OPORT
proto $OPROTO
dev tun
ca $EZ/pki/ca.crt
cert $EZ/pki/issued/server.crt
key $EZ/pki/private/server.key
dh $EZ/pki/dh.pem
tls-crypt $EZ/tc.key
server 10.8.0.0 255.255.255.0
push "redirect-gateway def1 bypass-dhcp"
push "dhcp-option DNS 1.1.1.1"
keepalive 10 120
cipher AES-256-GCM
auth SHA256
user nobody
group nogroup
persist-key
persist-tun
EOF
  [ "$OPROTO" = udp ] && echo 'explicit-exit-notify 1' >> /etc/openvpn/server/server.conf

  echo 'net.ipv4.ip_forward=1' > /etc/sysctl.d/99-openvpn.conf
  sysctl --system >/dev/null 2>&1 || true

  iptables -t nat -C POSTROUTING -s 10.8.0.0/24 -o "$IFACE" -j MASQUERADE 2>/dev/null || \
    iptables -t nat -A POSTROUTING -s 10.8.0.0/24 -o "$IFACE" -j MASQUERADE

  netfilter-persistent save >/dev/null 2>&1 || true
  systemctl enable --now openvpn-server@server

  pem(){ sed -n '/-----BEGIN/,/-----END/p' "$1"; }
  {
    echo "client"
    echo "dev tun"
    echo "proto $OPROTO"
    echo "remote $IP $OPORT"
    echo "nobind"
    echo "persist-key"
    echo "persist-tun"
    echo "remote-cert-tls server"
    echo "cipher AES-256-GCM"
    echo "auth SHA256"
    echo '<ca>'; pem "$EZ/pki/ca.crt"; echo '</ca>'
    echo '<cert>'; pem "$EZ/pki/issued/client1.crt"; echo '</cert>'
    echo '<key>'; pem "$EZ/pki/private/client1.key"; echo '</key>'
    echo '<tls-crypt>'; cat "$EZ/tc.key"; echo '</tls-crypt>'
  } > /root/client1.ovpn
  chmod 600 /root/client1.ovpn

  if systemctl is-active --quiet openvpn-server@server; then
    OVPN_JSON=$(jq -n --arg proto "$OPROTO" --argjson port "$OPORT" \
      '{enabled:true,proto:$proto,port:$port}')
  fi
fi

if [ "$SSH_TUNNEL" = true ]; then
  echo "=== Configuring SSH tunnel ==="
  id tunnel >/dev/null 2>&1 || useradd -m -s /usr/sbin/nologin tunnel
  mkdir -p /home/tunnel/.ssh
  printf '%s\n' "$PUBKEY" > /home/tunnel/.ssh/authorized_keys
  chmod 700 /home/tunnel/.ssh
  chmod 600 /home/tunnel/.ssh/authorized_keys
  chown -R tunnel:tunnel /home/tunnel/.ssh

  cat >> /etc/ssh/sshd_config <<EOF
Match User tunnel
  AllowTcpForwarding yes
  X11Forwarding no
  PermitTunnel no
  GatewayPorts no
  AllowAgentForwarding no
  PermitTTY no
  ForceCommand /usr/sbin/nologin
EOF
  systemctl restart ssh
  SSH_JSON='{"enabled":true,"user":"tunnel","port":22}'
fi

# Write completion marker
jq -n \
  --argjson reality "$REALITY_JSON" \
  --argjson openvpn "$OVPN_JSON" \
  --argjson ssh_tunnel "$SSH_JSON" \
  --arg ip "$IP" \
  '{status:"ready",external_ip:$ip,reality:$reality,openvpn:$openvpn,ssh_tunnel:$ssh_tunnel}' \
  > /etc/vm-setup-complete.json

echo "=== Provisioning complete ==="
'''

def main() -> None:
    print(colour("\n=== TCP companion VM: REALITY / OpenVPN / SSH SOCKS ===\n", BOLD))
    print("This adds a VM beside Cloud Run. It does not and cannot change *.run.app.\n")

    project_id = project()
    zone = ask("GCE zone", "us-central1-a")
    region = "-".join(zone.split("-")[:-1])
    name = ask("VM name", "saeka-tcp")
    machine = ask("Machine type", "e2-micro")
    tag = f"{name}-tcp"

    reality = ask_yes_no("Enable VLESS + REALITY on raw TCP?", True)
    ovpn = ask_yes_no("Enable OpenVPN?", True)
    ssh_tunnel = ask_yes_no("Enable restricted SSH SOCKS tunnel?", True)

    if not (reality or ovpn or ssh_tunnel):
        die("select at least one protocol")

    rport = int(ask("REALITY port", "443")) if reality else 443
    sni = ask("REALITY server name", "www.microsoft.com") if reality else "www.microsoft.com"
    dest = ask("REALITY destination host:port", f"{sni}:443") if reality else f"{sni}:443"

    oport = int(ask("OpenVPN port", "1194")) if ovpn else 1194
    oproto = ask("OpenVPN protocol (udp/tcp)", "udp").lower() if ovpn else "udp"
    if oproto not in {"udp", "tcp"}:
        die("OpenVPN protocol must be udp or tcp")

    key_path = WORKDIR / f"{name}_tunnel_key"
    WORKDIR.mkdir(parents=True, exist_ok=True)
    if ssh_tunnel and not key_path.exists():
        cmd(["ssh-keygen", "-t", "ed25519", "-N", "", "-f", str(key_path), "-q"])
    pubkey = (key_path.with_suffix(".pub").read_text().strip() if ssh_tunnel else "")

    ip = regional_ip(project_id, region, f"{name}-ip")

    if reality:
        firewall(project_id, f"{tag}-reality", "tcp", rport, tag)
    if ovpn:
        firewall(project_id, f"{tag}-openvpn", oproto, oport, tag)
    firewall(project_id, f"{tag}-iap", "tcp", 22, tag, "35.235.240.0/20")

    cfg = {
        "reality": str(reality).lower(),
        "ovpn": str(ovpn).lower(),
        "ssh": str(ssh_tunnel).lower(),
        "reality_port": rport,
        "reality_dest": dest,
        "reality_sni": sni,
        "ovpn_port": oport,
        "ovpn_proto": oproto,
        "pubkey": pubkey,
    }

    script_path = WORKDIR / f"{name}-startup.sh"
    script_path.write_text(startup(cfg))
    script_path.chmod(0o700)

    create_vm(project_id, zone, name, machine, ip, tag, script_path)
    result = wait_ready(project_id, zone, name)

    domain = ask("DNS domain for VM sibling record (blank to skip)", "")
    fqdn = None
    if domain:
        subdomain = ask("VM subdomain", "vpn")
        token = os.environ.get("CF_API_TOKEN") or getpass.getpass("Cloudflare DNS API token (blank to skip): ")
        if token:
            fqdn = cloudflare(domain, subdomain, ip, token)

    host = fqdn or ip
    print(colour(f"\nVM ready: {host} (static IP {ip})", GREEN))

    if result.get("reality", {}).get("enabled"):
        r = result["reality"]
        print(f"REALITY: vless://{r['uuid']}@{host}:{r['port']}?encryption=none&flow=xtls-rprx-vision&security=reality&sni={r['serverName']}&fp=chrome&pbk={r['publicKey']}&sid={r['shortId']}&type=tcp#saeka-reality")

    if ovpn and scp(project_id, zone, name, "/root/client1.ovpn", WORKDIR / f"{name}-client1.ovpn"):
        (WORKDIR / f"{name}-client1.ovpn").chmod(0o600)
        print(f"OpenVPN profile: {WORKDIR / f'{name}-client1.ovpn'}")

    if ssh_tunnel:
        print(f"SSH SOCKS: ssh -i {key_path} -D 1080 -N tunnel@{host}")

    print(colour("\nCloud Run remains the HTTP endpoint; use the VM host for TCP/UDP protocols.", YELLOW))

if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        print("\nAborted.")
        raise SystemExit(130)
