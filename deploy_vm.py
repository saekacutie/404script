#!/usr/bin/env python3
"""Provision the raw-TCP companion VM for the Cloud Run deployment.
Cloud Run remains the HTTP frontend for WebSocket, HTTPUpgrade, XHTTP and gRPC.
This script provisions a separate Compute Engine VM for protocols that require
an internet-facing TCP/UDP socket: VLESS+REALITY, OpenVPN and SSH SOCKS.
It deliberately never attempts to repoint a *.run.app hostname.
Requirements: Python 3, gcloud authenticated, and an active GCP project.
Optional DNS: set CF_API_TOKEN and pass a domain when prompted. The token must
only have Cloudflare Zone DNS Edit permission.

VLESS+REALITY runs as XHTTP (default) or as raw TCP with the Vision flow. With
XHTTP the VM can also open a second, TLS-protected listener (default tcp/8443,
path /vless-saeka-xh, self-signed cert that deploy.sh pins). The Cloud Run
"Reality Combo" engine (deploy.sh option 9) relays XHTTP to that listener, so
one UUID works directly over REALITY and through Cloud Run.

OpenVPN logins: the same "user:pass,user2:pass2" list you give deploy.sh
(export SSH_USERS first to share it between both). Only PBKDF2 hashes are sent
to the VM. Clients then need BOTH the client certificate (inside the .ovpn) and
a login. Leave it blank for certificate-only auth.
NOTE: the Cloud Run relay (/saeka-ovpn) needs OpenVPN on proto TCP.

Non-interactive mode: pass --auto (or set DEPLOY_VM_AUTO=1) to skip every
prompt. Text/number prompts use their default unless you set the matching
DEPLOY_VM_<LABEL> env var (e.g. DEPLOY_VM_GCE_ZONE, DEPLOY_VM_VM_NAME,
DEPLOY_VM_MACHINE_TYPE). The protocol toggles use fixed names instead:
DEPLOY_VM_ENABLE_REALITY, DEPLOY_VM_ENABLE_OVPN, DEPLOY_VM_ENABLE_SSH (each
"y"/"n", default "y"). REALITY extras: DEPLOY_VM_REALITY_TRANSPORT (xhttp|tcp),
DEPLOY_VM_XHTTP_PATH, DEPLOY_VM_XHTTP_MODE, DEPLOY_VM_ENABLE_RELAY (y/n),
DEPLOY_VM_RELAY_PORT, DEPLOY_VM_RELAY_PATH. OpenVPN logins come from OVPN_USERS
(or SSH_USERS, same as before) and the Cloudflare token still comes from
CF_API_TOKEN. The external IP is always auto-reserved via gcloud - it was never
typed by hand.
"""
from __future__ import annotations
import getpass
import hashlib
import json
import os
import re
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
PBKDF2_ITER = 200_000   # must match the auth script inside STARTUP

PATH_RE = re.compile(r"^/[A-Za-z0-9._~/-]*$")
XHTTP_MODES = {"auto", "packet-up", "stream-up", "stream-one"}

AUTO = "--auto" in sys.argv or os.environ.get("DEPLOY_VM_AUTO", "") == "1"

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

def _env_key(label: str) -> str:
    return "DEPLOY_VM_" + re.sub(r"[^A-Za-z0-9]+", "_", label).strip("_").upper()

def ask(label: str, default: str | None = None, env_var: str | None = None) -> str:
    if AUTO:
        value = os.environ.get(env_var or _env_key(label), "")
        chosen = value or (default or "")
        print(colour(f"  {label}: {chosen}", CYAN))
        return chosen
    suffix = f" [{default}]" if default is not None else ""
    value = input(colour(f"  {label}{suffix}: ", CYAN)).strip()
    return value or (default or "")

def ask_yes_no(label: str, default: bool = True, env_var: str | None = None) -> bool:
    if AUTO:
        env = os.environ.get(env_var or _env_key(label), "")
        chosen = default if not env else env.strip().lower().startswith("y")
        print(colour(f"  {label}: {'yes' if chosen else 'no'}", CYAN))
        return chosen
    answer = input(colour(f"  {label} ({'Y/n' if default else 'y/N'}): ", CYAN)).strip().lower()
    return default if not answer else answer.startswith("y")

def ask_secret(label: str, env_var: str) -> str:
    if AUTO:
        return os.environ.get(env_var, "")
    return getpass.getpass(f"  {label}: ").strip()

def ask_port(label: str, default: int, env_var: str | None = None) -> int:
    raw = ask(label, str(default), env_var)
    if not raw.isdigit() or not 1 <= int(raw) <= 65535:
        die(f"{label} must be a number from 1 to 65535")
    return int(raw)

def valid_path(label: str, value: str) -> str:
    if not PATH_RE.fullmatch(value):
        die(f"{label} must start with / and use only letters, digits and . _ ~ / -")
    return value

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

def hash_users(csv: str) -> str:
    out = []
    for pair in filter(None, (p.strip() for p in csv.split(","))):
        user, sep, password = pair.partition(":")
        if not sep or not re.fullmatch(r"[a-z_][a-z0-9_-]{0,31}", user):
            die(f"invalid OpenVPN user entry '{user}' (lowercase letters, digits, _ or -; format user:pass)")
        if not password or re.search(r"[,@\s]", password):
            die(f"password for '{user}' is empty or contains a comma, @ or whitespace")
        salt = secrets.token_hex(16)
        digest = hashlib.pbkdf2_hmac("sha256", password.encode(), bytes.fromhex(salt), PBKDF2_ITER)
        out.append(f"{user}:{salt}:{digest.hex()}")
    return ",".join(out)

def startup(config: dict) -> str:
    q = lambda value: shlex.quote(str(value))
    values = {key: q(value) for key, value in config.items()}
    return STARTUP.replace("@@REALITY@@", values["reality"])\
        .replace("@@OVPN@@", values["ovpn"])\
        .replace("@@SSH@@", values["ssh"])\
        .replace("@@RPORT@@", values["reality_port"])\
        .replace("@@DEST@@", values["reality_dest"])\
        .replace("@@SNI@@", values["reality_sni"])\
        .replace("@@RTRANSPORT@@", values["reality_transport"])\
        .replace("@@XPATH@@", values["xhttp_path"])\
        .replace("@@XMODE@@", values["xhttp_mode"])\
        .replace("@@RELAYPORT@@", values["relay_port"])\
        .replace("@@RELAYPATH@@", values["relay_path"])\
        .replace("@@RELAY@@", values["relay"])\
        .replace("@@OPORT@@", values["ovpn_port"])\
        .replace("@@OPROTO@@", values["ovpn_proto"])\
        .replace("@@PUBKEY@@", values["pubkey"])\
        .replace("@@USERS@@", values["users"])

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
                "--tunnel-through-iap", "--quiet", "--command", remote], capture=True, check=False)

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
    staged = "/tmp/client1.ovpn"
    prep = ssh(project_id, zone, name, f"sudo cp {remote} {staged} && sudo chmod 644 {staged}")
    if prep.returncode:
        return False
    result = cmd(["gcloud", "compute", "scp", f"{name}:{staged}", str(local),
                  "--project", project_id, "--zone", zone, "--tunnel-through-iap", "--quiet"], check=False)
    ssh(project_id, zone, name, f"rm -f {staged}")
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
# STARTUP SCRIPT - Xray >= 26.3.27 (XHTTP), OpenVPN with cert + user:pass
# ------------------------------------------------------------------------------
STARTUP = r'''#!/bin/bash
set -euo pipefail
exec >> /var/log/vm-setup.log 2>&1
export DEBIAN_FRONTEND=noninteractive

if [ -f /etc/vm-setup-complete.json ]; then
  echo "=== Already provisioned; skipping (delete the VM for a clean rebuild) ==="
  exit 0
fi

echo "=== Starting VM provisioning ==="

apt-get update -y
apt-get install -y curl unzip ca-certificates openssl jq python3

REALITY=@@REALITY@@; OVPN=@@OVPN@@; SSH_TUNNEL=@@SSH@@
RPORT=@@RPORT@@; DEST=@@DEST@@; SNI=@@SNI@@
RTRANSPORT=@@RTRANSPORT@@; XPATH=@@XPATH@@; XMODE=@@XMODE@@
RELAY=@@RELAY@@; RELAYPORT=@@RELAYPORT@@; RELAYPATH=@@RELAYPATH@@
OPORT=@@OPORT@@; OPROTO=@@OPROTO@@; PUBKEY=@@PUBKEY@@
USERS=@@USERS@@

IFACE=$(ip route | awk '/default/ {print $5; exit}')
IP=$(curl -sf -H 'Metadata-Flavor: Google' http://metadata.google.internal/computeMetadata/v1/instance/network-interfaces/0/access-configs/0/external-ip)

rm -f /etc/xray/config.json /usr/local/etc/xray/config.json
mkdir -p /usr/local/etc/xray

REALITY_JSON='{"enabled":false}'; OVPN_JSON='{"enabled":false}'; SSH_JSON='{"enabled":false}'
AUTH_ON=false

setup_reality() {
  echo "=== Installing Xray ==="
  curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh | bash -s -- install || return 1

  XRAY=/usr/local/bin/xray
  XDIR=/usr/local/etc/xray
  RELAY_CRT=""; RELAY_KEY=""
  mkdir -p "$XDIR"
  echo "Xray version: $("$XRAY" version 2>&1 | head -n1 || true)"

  UUID=$(cat /proc/sys/kernel/random/uuid)
  KEYS=$("$XRAY" x25519) || return 1
  PRIVATE=$(printf '%s\n' "$KEYS" | awk -F': *' '/PrivateKey/ {print $2; exit}')
  PUBLIC=$(printf '%s\n' "$KEYS" | awk -F': *' '/PublicKey/ {print $2; exit}')
  if [ -z "$PRIVATE" ] || [ -z "$PUBLIC" ]; then
    echo "ERROR: could not parse the output of 'xray x25519':"
    echo "$KEYS"
    return 1
  fi
  SID=$(openssl rand -hex 8)

  if [ "$RTRANSPORT" = xhttp ] && [ "$RELAY" = true ]; then
    echo "=== Creating self-signed cert for the Cloud Run relay listener ==="
    RELAY_CRT="$XDIR/relay.crt"; RELAY_KEY="$XDIR/relay.key"
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 3650 \
      -subj "/CN=vm-relay" -addext "subjectAltName=DNS:vm-relay" \
      -keyout "$RELAY_KEY" -out "$RELAY_CRT" || return 1
    XUSER=$(systemctl show -p User --value xray 2>/dev/null || true)
    [ -n "$XUSER" ] || XUSER=root
    chown "$XUSER" "$RELAY_KEY" "$RELAY_CRT"
    chmod 600 "$RELAY_KEY"
    chmod 644 "$RELAY_CRT"
  else
    RELAY=false
  fi

  export UUID PRIVATE PUBLIC SID DEST SNI RPORT RTRANSPORT XPATH XMODE RELAY RELAYPORT RELAYPATH RELAY_CRT RELAY_KEY

  python3 - <<'PYEOF' > "$XDIR/config.json" || return 1
import json, os

e = os.environ
transport = e["RTRANSPORT"]

reality = {
    "show": False,
    "dest": e["DEST"],
    "xver": 0,
    "serverNames": [e["SNI"]],
    "privateKey": e["PRIVATE"],
    "shortIds": [e["SID"]],
}
stream = {"security": "reality", "realitySettings": reality}
client = {"id": e["UUID"]}
if transport == "xhttp":
    stream["network"] = "xhttp"
    stream["xhttpSettings"] = {"path": e["XPATH"], "mode": e["XMODE"]}
else:
    stream["network"] = "tcp"
    client["flow"] = "xtls-rprx-vision"

inbounds = [{
    "tag": "reality-in",
    "listen": "0.0.0.0",
    "port": int(e["RPORT"]),
    "protocol": "vless",
    "settings": {"clients": [client], "decryption": "none"},
    "streamSettings": stream,
}]

if e["RELAY"] == "true":
    inbounds.append({
        "tag": "relay-in",
        "listen": "0.0.0.0",
        "port": int(e["RELAYPORT"]),
        "protocol": "vless",
        "settings": {"clients": [{"id": e["UUID"]}], "decryption": "none"},
        "streamSettings": {
            "network": "xhttp",
            "xhttpSettings": {"path": e["RELAYPATH"], "mode": "auto"},
            "security": "tls",
            "tlsSettings": {
                "alpn": ["h2", "http/1.1"],
                "certificates": [{"certificateFile": e["RELAY_CRT"], "keyFile": e["RELAY_KEY"]}],
            },
        },
    })

config = {
    "log": {"loglevel": "warning"},
    "inbounds": inbounds,
    "outbounds": [{"protocol": "freedom", "tag": "direct"}],
}
print(json.dumps(config, indent=2))
PYEOF

  mkdir -p /etc/xray
  ln -sf "$XDIR/config.json" /etc/xray/config.json

  if ! "$XRAY" run -test -config "$XDIR/config.json"; then
    echo "ERROR: xray rejected the generated config"
    return 1
  fi

  systemctl enable xray
  systemctl restart xray
  sleep 2

  if ! systemctl is-active --quiet xray; then
    echo "WARNING: Xray service failed to start"
    systemctl status xray --no-pager || true
    journalctl -u xray --no-pager -n 30 || true
    return 1
  fi

  echo "Xray+REALITY started successfully"
  REALITY_JSON=$(python3 - <<'PYEOF'
import base64, json, os

e = os.environ
out = {
    "enabled": True,
    "transport": e["RTRANSPORT"],
    "uuid": e["UUID"],
    "publicKey": e["PUBLIC"],
    "shortId": e["SID"],
    "serverName": e["SNI"],
    "dest": e["DEST"],
    "port": int(e["RPORT"]),
    "path": e["XPATH"],
    "mode": e["XMODE"],
    "relay": {"enabled": False},
}
if e["RELAY"] == "true":
    with open(e["RELAY_CRT"], "rb") as f:
        cert = base64.b64encode(f.read()).decode()
    out["relay"] = {
        "enabled": True,
        "port": int(e["RELAYPORT"]),
        "path": e["RELAYPATH"],
        "certB64": cert,
    }
print(json.dumps(out))
PYEOF
)
}

if [ "$REALITY" = true ]; then
  setup_reality || echo "WARNING: REALITY setup failed - see /var/log/vm-setup.log"
fi

if [ "$OVPN" = true ]; then
  echo "=== Installing OpenVPN ==="
  apt-get install -y openvpn easy-rsa iptables-persistent

  EZ=/etc/openvpn/easy-rsa; mkdir -p "$EZ"; cp -r /usr/share/easy-rsa/* "$EZ"/; cd "$EZ"
  ./easyrsa --batch init-pki
  ./easyrsa --batch build-ca nopass
  ./easyrsa --batch gen-req server nopass
  ./easyrsa --batch sign-req server server
  ./easyrsa --batch gen-req client1 nopass
  ./easyrsa --batch sign-req client client1
  openvpn --genkey tls-crypt "$EZ/tc.key"

  mkdir -p /etc/openvpn/server
  cat > /etc/openvpn/server/server.conf <<EOF
port $OPORT
proto $OPROTO
dev tun
ca $EZ/pki/ca.crt
cert $EZ/pki/issued/server.crt
key $EZ/pki/private/server.key
dh none
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

  if [ -n "$USERS" ]; then
    echo "=== Enabling OpenVPN user:pass login ==="
    printf '%s\n' "$USERS" | tr ',' '\n' > /etc/openvpn/users.hash
    chown nobody:nogroup /etc/openvpn/users.hash
    chmod 600 /etc/openvpn/users.hash

    cat > /etc/openvpn/auth.py <<'AUTHEOF'
#!/usr/bin/python3
import hashlib, hmac, sys
try:
    with open(sys.argv[1]) as f:
        user = f.readline().rstrip("\n")
        password = f.readline().rstrip("\n")
    ok = False
    with open("/etc/openvpn/users.hash") as f:
        for line in f:
            parts = line.strip().split(":")
            if len(parts) != 3:
                continue
            u, salt, expected = parts
            if hmac.compare_digest(u, user):
                got = hashlib.pbkdf2_hmac("sha256", password.encode(), bytes.fromhex(salt), 200000).hex()
                ok = hmac.compare_digest(got, expected)
                break
    sys.exit(0 if ok else 1)
except Exception:
    sys.exit(1)
AUTHEOF
    chmod 755 /etc/openvpn/auth.py

    cat >> /etc/openvpn/server/server.conf <<EOF
script-security 2
auth-user-pass-verify /etc/openvpn/auth.py via-file
verify-client-cert require
EOF
    AUTH_ON=true
  fi

  mkdir -p /etc/systemd/system/openvpn-server@server.service.d
  cat > /etc/systemd/system/openvpn-server@server.service.d/override.conf <<EOF
[Service]
LimitNPROC=infinity
EOF
  systemctl daemon-reload

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
    echo "resolv-retry infinite"
    echo "persist-key"
    echo "persist-tun"
    echo "remote-cert-tls server"
    echo "cipher AES-256-GCM"
    echo "auth SHA256"
    echo "verb 3"
    if [ "$AUTH_ON" = true ]; then echo "auth-user-pass"; fi
    echo '<ca>'; pem "$EZ/pki/ca.crt"; echo '</ca>'
    echo '<cert>'; pem "$EZ/pki/issued/client1.crt"; echo '</cert>'
    echo '<key>'; pem "$EZ/pki/private/client1.key"; echo '</key>'
    echo '<tls-crypt>'; cat "$EZ/tc.key"; echo '</tls-crypt>'
  } > /root/client1.ovpn
  chmod 600 /root/client1.ovpn

  if systemctl is-active --quiet openvpn-server@server; then
    OVPN_JSON=$(jq -n --arg proto "$OPROTO" --argjson port "$OPORT" --argjson auth "$AUTH_ON" \
      '{enabled:true,proto:$proto,port:$port,auth:$auth}')
  else
    echo "WARNING: openvpn-server@server failed to start"
    journalctl -u openvpn-server@server --no-pager -n 30 || true
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

    reality = ask_yes_no("Enable VLESS + REALITY on raw TCP?", True, env_var="DEPLOY_VM_ENABLE_REALITY")
    ovpn = ask_yes_no("Enable OpenVPN?", True, env_var="DEPLOY_VM_ENABLE_OVPN")
    ssh_tunnel = ask_yes_no("Enable restricted SSH SOCKS tunnel?", True, env_var="DEPLOY_VM_ENABLE_SSH")

    if not (reality or ovpn or ssh_tunnel):
        die("select at least one protocol")

    rport = ask_port("REALITY port", 443) if reality else 443
    sni = ask("REALITY server name", "www.maya.ph") if reality else "www.maya.ph"
    dest = ask("REALITY destination host:port", f"{sni}:443") if reality else f"{sni}:443"

    rtransport = "xhttp"
    xpath = "/xh-saeka"
    xmode = "auto"
    relay = False
    relay_port = 8443
    relay_path = "/vless-saeka-xh"
    if reality:
        rtransport = ask("REALITY transport (xhttp or tcp)", "xhttp",
                         env_var="DEPLOY_VM_REALITY_TRANSPORT").lower()
        if rtransport not in {"xhttp", "tcp"}:
            die("REALITY transport must be xhttp or tcp")
        if rtransport == "xhttp":
            xpath = valid_path("XHTTP path", ask("XHTTP path", "/xh-saeka", env_var="DEPLOY_VM_XHTTP_PATH"))
            xmode = ask("XHTTP mode (auto/packet-up/stream-up/stream-one)", "auto",
                        env_var="DEPLOY_VM_XHTTP_MODE").lower()
            if xmode not in XHTTP_MODES:
                die("XHTTP mode must be auto, packet-up, stream-up or stream-one")
            relay = ask_yes_no("Also open a TLS relay listener for the Cloud Run XHTTP relay?", True,
                               env_var="DEPLOY_VM_ENABLE_RELAY")
            if relay:
                relay_port = ask_port("Relay listener port", 8443, "DEPLOY_VM_RELAY_PORT")
                relay_path = valid_path("Relay path", ask("Relay path", "/vless-saeka-xh",
                                                          env_var="DEPLOY_VM_RELAY_PATH"))
                if relay_port in {rport, 22}:
                    die(f"relay port {relay_port} clashes with the REALITY port or SSH")

    oport = ask_port("OpenVPN port", 1194) if ovpn else 1194
    oproto = "udp"
    users_hash = ""
    if ovpn:
        oproto = ask("OpenVPN protocol (udp/tcp; tcp is REQUIRED for the Cloud Run relay)", "udp",
                     env_var="DEPLOY_VM_OVPN_PROTO").lower()
        if oproto not in {"udp", "tcp"}:
            die("OpenVPN protocol must be udp or tcp")
        if oproto == "tcp" and reality and oport in {rport, relay_port if relay else 0}:
            die(f"OpenVPN port {oport}/tcp clashes with a REALITY/relay port")
        raw_users = os.environ.get("SSH_USERS", "")
        if raw_users:
            print(colour("  Using logins from the SSH_USERS environment variable.", YELLOW))
        else:
            raw_users = ask_secret(
                "OpenVPN logins user:pass,user2:pass2 (blank = certificate only)", "OVPN_USERS")
        users_hash = hash_users(raw_users) if raw_users else ""
        if not users_hash:
            print(colour("  No logins: anyone holding the .ovpn file can connect.", YELLOW))

    key_path = WORKDIR / f"{name}_tunnel_key"
    WORKDIR.mkdir(parents=True, exist_ok=True)
    if ssh_tunnel and not key_path.exists():
        cmd(["ssh-keygen", "-t", "ed25519", "-N", "", "-f", str(key_path), "-q"])
    pubkey = (key_path.with_suffix(".pub").read_text().strip() if ssh_tunnel else "")

    ip = regional_ip(project_id, region, f"{name}-ip")

    if reality:
        firewall(project_id, f"{tag}-reality", "tcp", rport, tag)
        if relay:
            firewall(project_id, f"{tag}-relay", "tcp", relay_port, tag)
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
        "reality_transport": rtransport,
        "xhttp_path": xpath,
        "xhttp_mode": xmode,
        "relay": str(relay).lower(),
        "relay_port": relay_port,
        "relay_path": relay_path,
        "ovpn_port": oport,
        "ovpn_proto": oproto,
        "pubkey": pubkey,
        "users": users_hash,
    }

    script_path = WORKDIR / f"{name}-startup.sh"
    script_path.write_text(startup(cfg))
    script_path.chmod(0o700)

    create_vm(project_id, zone, name, machine, ip, tag, script_path)
    result = wait_ready(project_id, zone, name)

    reality_info = result.get("reality", {"enabled": False})
    if reality and not reality_info.get("enabled"):
        print(colour("  REALITY did not come up; see /var/log/vm-setup.log on the VM.", YELLOW))
    elif reality and reality_info.get("transport") != rtransport:
        print(colour(f"  This VM was built earlier with transport '{reality_info.get('transport', 'tcp')}', "
                     f"not '{rtransport}'. Delete the VM for a clean rebuild.", YELLOW))

    domain = ask("DNS domain for VM sibling record (blank to skip)", "")
    fqdn = None
    if domain:
        subdomain = ask("VM subdomain", "vpn")
        token = os.environ.get("CF_API_TOKEN") or ask_secret("Cloudflare DNS API token (blank to skip)", "CF_API_TOKEN")
        if token:
            fqdn = cloudflare(domain, subdomain, ip, token)

    host = fqdn or ip
    print(colour(f"\nVM ready: {host} (static IP {ip})", GREEN))

    info_path = WORKDIR / f"{name}-info.json"
    info_path.write_text(json.dumps({
        "vm_name": name,
        "host": host,
        "ip": ip,
        "zone": zone,
        "ovpn_enabled": bool(ovpn),
        "ovpn_port": oport if ovpn else None,
        "ovpn_proto": oproto if ovpn else None,
        "ssh_tunnel_enabled": bool(ssh_tunnel),
        "reality": reality_info,
        "updated": time.time(),
    }, indent=2))
    info_path.chmod(0o600)

    if reality_info.get("enabled"):
        r = reality_info
        if r.get("transport") == "xhttp":
            enc_path = urllib.parse.quote(r["path"], safe="")
            print(f"REALITY (XHTTP): vless://{r['uuid']}@{host}:{r['port']}?encryption=none&security=reality"
                  f"&sni={r['serverName']}&fp=chrome&pbk={r['publicKey']}&sid={r['shortId']}"
                  f"&type=xhttp&path={enc_path}&mode={r['mode']}#saeka-reality-xhttp")
            if r.get("relay", {}).get("enabled"):
                print(f"  Cloud Run relay listener: tcp/{r['relay']['port']} path {r['relay']['path']} "
                      f"(deploy.sh option 9 wires it up)")
        else:
            print(f"REALITY: vless://{r['uuid']}@{host}:{r['port']}?encryption=none&flow=xtls-rprx-vision"
                  f"&security=reality&sni={r['serverName']}&fp=chrome&pbk={r['publicKey']}&sid={r['shortId']}"
                  f"&type=tcp#saeka-reality")

    if ovpn:
        local_ovpn = WORKDIR / f"{name}-client1.ovpn"
        if scp(project_id, zone, name, "/root/client1.ovpn", local_ovpn):
            local_ovpn.chmod(0o600)
            print(f"OpenVPN profile: {local_ovpn}")
            if result.get("openvpn", {}).get("auth"):
                print("  Clients are asked for a username and password in addition to the client certificate.")
            else:
                print("  Certificate-only authentication (no password required).")

    if ssh_tunnel:
        print(f"SSH SOCKS tunnel key: {key_path}")
        print(f"  Connect: ssh -i {key_path} -D 1080 -N tunnel@{host}")

    print(colour("\n=== Deployment finished successfully ===", GREEN))


if __name__ == "__main__":
    main()
