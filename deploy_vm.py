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
import urllib.parse
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

def create_vm(project_id: str, zone: str, name: str, machine: str, ip: str, tag: str, script: Path) -> bool:
    """Create the VM. Returns False when it already existed (and is reused)."""
    if gcloud_json(["compute", "instances", "describe", name, "--zone", zone, "--project", project_id]):
        print(colour(f"  Reusing existing VM {name}; delete it for a clean rebuild.", YELLOW))
        return False
    cmd(["gcloud", "compute", "instances", "create", name, "--project", project_id,
         "--zone", zone, "--machine-type", machine, "--image-family=debian-12",
         "--image-project=debian-cloud", "--address", ip, "--tags", tag,
         "--metadata=enable-guest-attributes=TRUE",
         f"--metadata-from-file=startup-script={script}"])
    return True

def guest_result(project_id: str, zone: str, name: str) -> dict | None:
    """Setup result the VM published as a guest attribute (no SSH needed)."""
    r = cmd(["gcloud", "compute", "instances", "get-guest-attributes", name, "--zone", zone,
             "--project", project_id, "--query-path=saeka/ready", "--format=value(value)"],
            capture=True, check=False)
    if r.returncode or not r.stdout.strip():
        return None
    try:
        data = json.loads(r.stdout.strip())
        return data if isinstance(data, dict) else None
    except json.JSONDecodeError:
        return None

def pick_zone(project_id: str, region: str) -> str:
    r = cmd(["gcloud", "compute", "zones", "list", "--project", project_id,
             f"--filter=region:{region} AND status=UP", "--format=value(name)"], capture=True, check=False)
    zones = sorted(z.strip() for z in (r.stdout or "").split() if z.strip())
    return zones[0] if zones else f"{region}-a"

def ssh(project_id: str, zone: str, name: str, remote: str) -> subprocess.CompletedProcess[str]:
    return cmd(["gcloud", "compute", "ssh", name, "--project", project_id, "--zone", zone,
                "--tunnel-through-iap", "--command", remote], capture=True, check=False)

AUTO = False

def wait_ready(project_id: str, zone: str, name: str, timeout: int = 900) -> dict:
    end = time.time() + timeout
    while time.time() < end:
        data = guest_result(project_id, zone, name)
        if data is None and not AUTO:                  # fall back to SSH through IAP
            result = ssh(project_id, zone, name, "sudo cat /etc/vm-setup-complete.json 2>/dev/null")
            if result.returncode == 0:
                try:
                    data = json.loads(result.stdout.strip())
                except json.JSONDecodeError:
                    data = None
        if data and data.get("status") == "ready":
            print()
            return data
        if data and data.get("status") == "failed":
            print()
            die(f"VM setup failed at script line {data.get('line')}. Read the log with: gcloud compute instances "
                f"get-serial-port-output {name} --zone {zone} --project {project_id} | tail -n 40")
        print("\r  Waiting for the VM to finish setup (about 2-4 minutes)...", end="", flush=True)
        time.sleep(10)
    print()
    die(f"VM setup timed out; read its log with: gcloud compute instances get-serial-port-output {name} "
        f"--zone {zone} --project {project_id} | tail -n 40")

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
# Any unexpected failure writes a marker, so the deploy script stops waiting and shows the log.
# The result is also published as a guest attribute, so the deployer can read it
# without SSH/IAP (which restricted lab accounts often can't use).
publish() { curl -sf -X PUT -H 'Metadata-Flavor: Google' --data-binary @"$1" \
  http://metadata.google.internal/computeMetadata/v1/instance/guest-attributes/saeka/ready >/dev/null 2>&1 || true; }
trap 'printf "{\"status\":\"failed\",\"line\":\"%s\"}" "$LINENO" > /etc/vm-setup-complete.json; publish /etc/vm-setup-complete.json' ERR
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

# Network tuning: BBR + bigger socket buffers.
cat > /etc/sysctl.d/98-saeka-net.conf <<'EOF'
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.ipv4.tcp_fastopen=3
net.core.rmem_max=16777216
net.core.wmem_max=16777216
EOF
sysctl --system >/dev/null 2>&1 || true

REALITY_JSON='{"enabled":false}'; OVPN_JSON='{"enabled":false}'; SSH_JSON='{"enabled":false}'

if [ "$REALITY" = true ]; then
  echo "=== Installing Xray + VLESS+REALITY ==="
  for _try in 1 2 3; do
    curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh | bash -s -- install && break
    echo "Xray install attempt $_try failed; retrying"; sleep 5
  done
  [ -x /usr/local/bin/xray ] || { echo "Xray binary missing after install"; exit 1; }

  UUID=$(cat /proc/sys/kernel/random/uuid)
  KEYS=$(/usr/local/bin/xray x25519)
  # Xray >= 25.x prints "PrivateKey:" / "Password (PublicKey):"; older builds
  # print "Private key:" / "Public key:". Match either so REALITY keys are never
  # silently empty (which makes Xray refuse to start).
  PRIVATE=$(printf '%s\n' "$KEYS" | awk -F': *' 'tolower($1) ~ /private.*key/ {print $NF; exit}')
  PUBLIC=$(printf '%s\n' "$KEYS" | awk -F': *' 'tolower($1) ~ /(public.*key)|password/ {print $NF; exit}')
  if [ -z "$PRIVATE" ] || [ -z "$PUBLIC" ]; then
    echo "could not parse x25519 keys from: $KEYS"
    exit 1
  fi
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
      routing: {domainStrategy: "AsIs", rules: [{
        type: "field", outboundTag: "block",
        ip: ["127.0.0.0/8","10.0.0.0/8","172.16.0.0/12","192.168.0.0/16","169.254.0.0/16","::1/128","fc00::/7","fe80::/10"]
      }]},
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
            serverNames: ($sni | split(",") | map(select(length > 0))),
            privateKey: $private,
            shortIds: [$sid]
          }
        }
      }],
      outbounds: [{protocol: "freedom", tag: "direct"}, {protocol: "blackhole", tag: "block"}]
    }' > /usr/local/etc/xray/config.json

  # Symlink so all expected paths get the same clean config (/etc/xray does not
  # exist on a fresh image; without mkdir this ln killed the whole script).
  mkdir -p /etc/xray
  ln -sf /usr/local/etc/xray/config.json /etc/xray/config.json
  chmod 644 /usr/local/etc/xray/config.json

  # Many connections at once: raise the service's file limit.
  mkdir -p /etc/systemd/system/xray.service.d
  printf '[Service]\nLimitNOFILE=1048576\n' > /etc/systemd/system/xray.service.d/limits.conf
  systemctl daemon-reload

  REALITY_ERR=""
  if ! XRAY_TEST=$(/usr/local/bin/xray run -test -config /usr/local/etc/xray/config.json 2>&1); then
    REALITY_ERR="config test failed: $(printf '%s' "$XRAY_TEST" | tail -n 3 | tr '\n' ' ')"
  else
    systemctl enable xray >/dev/null 2>&1 || true
    systemctl restart xray || true
    sleep 3
  fi

  if systemctl is-active --quiet xray && ss -ltn | grep -q ":$RPORT "; then
    echo "Xray+REALITY started successfully and is listening on :$RPORT"
    REALITY_JSON=$(jq -n \
      --arg uuid "$UUID" \
      --arg pbk "$PUBLIC" \
      --arg sid "$SID" \
      --arg sni "$SNI" \
      --arg dest "$DEST" \
      --argjson port "$RPORT" \
      '{enabled:true,uuid:$uuid,publicKey:$pbk,shortId:$sid,serverName:($sni|split(",")[0]),serverNames:($sni|split(",")),dest:$dest,port:$port}')
  else
    echo "WARNING: Xray service failed to start"
    systemctl status xray --no-pager || true
    [ -n "$REALITY_ERR" ] || REALITY_ERR="xray did not start: $(journalctl -u xray -n 5 --no-pager 2>/dev/null | tail -n 3 | tr '\n' ' ')"
    REALITY_JSON=$(jq -n --arg e "$REALITY_ERR" '{enabled:false,error:$e}')
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
publish /etc/vm-setup-complete.json

echo "=== Provisioning complete ==="
'''

def reality_link(host: str, r: dict) -> str:
    q = urllib.parse.quote
    return (f"vless://{r['uuid']}@{host}:{r['port']}?encryption=none&flow=xtls-rprx-vision&security=reality"
            f"&sni={q(r['serverName'])}&fp=chrome&pbk={r['publicKey']}&sid={r['shortId']}&type=tcp#saeka-reality")

def sni_list(value: str) -> str:
    """Comma list of server names; a bare domain also gets its www./apex twin."""
    names = [n.strip().lower() for n in value.split(",") if n.strip()]
    out = []
    for n in names:
        for v in (n, n[4:] if n.startswith("www.") else "www." + n):
            if v not in out and v.count(".") >= 1:
                out.append(v)
    return ",".join(out) or "www.microsoft.com,microsoft.com"

def main() -> None:
    global AUTO
    import argparse
    ap = argparse.ArgumentParser(description="Provision the REALITY / OpenVPN / SSH companion VM")
    ap.add_argument("--auto", action="store_true", help="no prompts: create everything and write --out")
    ap.add_argument("--region", default="us-central1")
    ap.add_argument("--zone", default="")
    ap.add_argument("--name", default="saeka-tcp")
    ap.add_argument("--machine", default="e2-micro")
    ap.add_argument("--reality-port", type=int, default=443)
    ap.add_argument("--sni", default="www.microsoft.com")
    ap.add_argument("--dest", default="")
    ap.add_argument("--ovpn-port", type=int, default=0, help="enable OpenVPN on this port (0 = off)")
    ap.add_argument("--out", default="", help="write the result JSON here (auto mode)")
    args = ap.parse_args()
    AUTO = args.auto

    print(colour("\n=== TCP companion VM: REALITY / OpenVPN / SSH SOCKS ===\n", BOLD))
    print("This adds a VM beside Cloud Run. It does not and cannot change *.run.app.\n")

    project_id = project()
    cmd(["gcloud", "services", "enable", "compute.googleapis.com", "--project", project_id, "--quiet"], check=False, capture=True)

    if AUTO:
        zone = args.zone or pick_zone(project_id, args.region)
        name, machine = args.name, args.machine
        reality, ovpn, ssh_tunnel = True, args.ovpn_port > 0, False
        rport, oport, oproto = args.reality_port, args.ovpn_port or 1194, "tcp"
        sni = sni_list(args.sni)
        dest = args.dest or f"{sni.split(',')[0]}:443"
        print(f"  Zone {zone}, VM {name} ({machine}), REALITY :{rport}, names {sni}")
    else:
        zone = ask("GCE zone", "us-central1-a")
        name = ask("VM name", "saeka-tcp")
        machine = ask("Machine type", "e2-micro")
        reality = ask_yes_no("Enable VLESS + REALITY on raw TCP?", True)
        ovpn = ask_yes_no("Enable OpenVPN?", True)
        ssh_tunnel = ask_yes_no("Enable restricted SSH SOCKS tunnel?", True)
        if not (reality or ovpn or ssh_tunnel):
            die("select at least one protocol")
        rport = int(ask("REALITY port", "443")) if reality else 443
        sni = sni_list(ask("REALITY server name(s), comma separated", "www.microsoft.com")) if reality else "www.microsoft.com"
        dest = ask("REALITY destination host:port", f"{sni.split(',')[0]}:443") if reality else f"{sni.split(',')[0]}:443"
        oport = int(ask("OpenVPN port", "1194")) if ovpn else 1194
        oproto = ask("OpenVPN protocol (udp/tcp) - must be tcp for the Cloud Run WS relay", "tcp").lower() if ovpn else "tcp"
        if oproto not in {"udp", "tcp"}:
            die("OpenVPN protocol must be udp or tcp")
    region = "-".join(zone.split("-")[:-1])
    tag = f"{name}-tcp"

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
        "reality": str(reality).lower(), "ovpn": str(ovpn).lower(), "ssh": str(ssh_tunnel).lower(),
        "reality_port": rport, "reality_dest": dest, "reality_sni": sni,
        "ovpn_port": oport, "ovpn_proto": oproto, "pubkey": pubkey,
    }
    script_path = WORKDIR / f"{name}-startup.sh"
    script_path.write_text(startup(cfg))
    script_path.chmod(0o700)

    existing = guest_result(project_id, zone, name)
    if existing and existing.get("status") == "ready" and existing.get("reality", {}).get("enabled") == reality:
        print(colour(f"  VM {name} is already set up - reusing it.", YELLOW))
        result = existing
    else:
        create_vm(project_id, zone, name, machine, ip, tag, script_path)
        result = wait_ready(project_id, zone, name)

    fqdn = None
    if not AUTO:
        domain = ask("DNS domain for VM sibling record (blank to skip)", "")
        if domain:
            subdomain = ask("VM subdomain", "vpn")
            token = os.environ.get("CF_API_TOKEN") or getpass.getpass("Cloudflare DNS API token (blank to skip): ")
            if token:
                fqdn = cloudflare(domain, subdomain, ip, token)

    host = fqdn or ip
    print(colour(f"\nVM ready: {host} (static IP {ip})", GREEN))

    out: dict = {"ip": ip, "host": host, "zone": zone, "name": name, "reality": {"enabled": False}}
    r = result.get("reality", {})
    if r.get("enabled"):
        link = reality_link(host, r)
        out["reality"] = dict(r, link=link)
        (WORKDIR / f"{name}-reality.txt").write_text(link + "\n")
        print(f"REALITY: {link}")
        print(f"  server names accepted: {', '.join(r.get('serverNames') or [r['serverName']])}   (link saved: {WORKDIR / f'{name}-reality.txt'})")
    elif reality:
        err = r.get("error", "unknown error")
        print(colour(f"REALITY did not start: {err}", RED))
        print(f"  Inspect: gcloud compute ssh {name} --zone {zone} --tunnel-through-iap --command 'sudo journalctl -u xray -n 30 --no-pager'")

    if ovpn and not AUTO and scp(project_id, zone, name, "/root/client1.ovpn", WORKDIR / f"{name}-client1.ovpn"):
        (WORKDIR / f"{name}-client1.ovpn").chmod(0o600)
        print(f"OpenVPN profile: {WORKDIR / f'{name}-client1.ovpn'}")
    elif ovpn:
        print(f"OpenVPN profile: gcloud compute scp {name}:/root/client1.ovpn . --zone {zone} --tunnel-through-iap")

    if ssh_tunnel:
        print(f"SSH SOCKS: ssh -i {key_path} -D 1080 -N tunnel@{host}")

    if args.out:
        Path(args.out).write_text(json.dumps(out))
    if AUTO:
        if reality and not out["reality"]["enabled"]:
            raise SystemExit(2)
        return

    print(colour("\nCloud Run remains the HTTP endpoint; use the VM host for TCP/UDP protocols.", YELLOW))
    run_url = ask("Cloud Run URL of your REALITY Combo service (deploy.sh option 9, blank to skip)", "")
    run_host = run_url.replace("https://", "").replace("http://", "").strip("/ ")
    if run_host:
        print(colour(f"\nCombo: wss://{run_host}/saeka-tcp  ->  Cloud Run first, then {host}:{rport if reality else '-'}", GREEN))
        if ovpn:
            print(colour(f"       wss://{run_host}/saeka-ovpn ->  {host}:{oport}", GREEN))
        print("If you haven't deployed it yet: run deploy.sh, choose 9 (it can create this VM for you).")

if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        print("\nAborted.")
        raise SystemExit(130)
