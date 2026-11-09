#!/bin/bash
# ==============================================================================
# CLIENT LINK / CONFIG GENERATOR
# ==============================================================================
# Usage: ./generate-client-links.sh <host> [port] [uuid_or_password] [fp]
#
# ECH and uTLS fingerprint (fp) are properties of the CLIENT's TLS dial, not of
# the server inbounds (those listen on plaintext 127.0.0.1; TLS is terminated
# upstream by Cloud Run or your load balancer). So this script emits:
#   1. share links (vless/trojan/vmess/ss) in each protocol's real URI format
#   2. a full Xray outbound JSON per protocol (built with python's json module,
#      so it is always valid JSON)
#
# CDN / fronting (Cloudflare, Cloud CDN, any proxying CDN):
#   CDN_ADDRESS=<edge ip or CDN-fronted domain> ./generate-client-links.sh <host>
# dials the CDN address while TLS SNI and the HTTP Host stay <host>, so the CDN
# routes the request to your service. xHTTP defaults to mode=packet-up, the mode
# every CDN can carry (plain request/response, no streaming bodies); override
# with XHTTP_MODE=stream-up (CDN must stream request bodies) or auto.
#
# Certificate pinning is OFF by default. Cloud Run / Google-managed leaf certs
# rotate regularly, and a pinned leaf makes the client fail with "no internet"
# the day the cert changes. Opt in with PIN=1 if you really want it.
# ==============================================================================
set -e

HOST="${1:?Usage: $0 <host> [port] [uuid_or_password] [fp]}"
PORT="${2:-443}"
USERID="${3:-saeka}"
FP="${4:-chrome}"   # chrome | firefox | safari | ios | android | edge | random

case "$FP" in
    chrome|firefox|safari|ios|android|edge|random|randomized) ;;
    *) echo "[-] Unknown fp '$FP', falling back to chrome"; FP="chrome";;
esac

command -v python3 >/dev/null 2>&1 || { echo "[-] python3 is required"; exit 1; }

CERT_SHA256_B64=""
if [ "${PIN:-0}" = "1" ] && command -v openssl >/dev/null 2>&1; then
    echo "[+] PIN=1: probing ${HOST}:${PORT} for its live certificate..."
    CERT_SHA256_B64=$(echo | timeout 5 openssl s_client -connect "${HOST}:${PORT}" -servername "${HOST}" 2>/dev/null \
        | openssl x509 -outform DER 2>/dev/null | openssl dgst -sha256 -binary | base64) || true
    [ -z "$CERT_SHA256_B64" ] && echo "[-] Could not fetch a live cert; pinning skipped."
fi

ECH_B64=""
if command -v dig >/dev/null 2>&1; then
    ECH_B64=$(dig +short HTTPS "${HOST}" 2>/dev/null | grep -o 'ech=[^ "]*' | head -1 | cut -d= -f2) || true
fi
ECH_B64="${ECH_OVERRIDE:-$ECH_B64}"

mkdir -p ./client-links
LINKS_FILE="./client-links/${HOST}-links.txt"

HOST="$HOST" PORT="$PORT" USERID="$USERID" FP="$FP" \
CERT_SHA256_B64="$CERT_SHA256_B64" ECH_B64="$ECH_B64" \
LINKS_FILE="$LINKS_FILE" OUT_DIR="./client-links" \
python3 -I - <<'PY'
import base64, json, os, urllib.parse

host = os.environ["HOST"]
port = int(os.environ["PORT"])
uid = os.environ["USERID"]
fp = os.environ["FP"]
pin = os.environ.get("CERT_SHA256_B64", "")
ech = os.environ.get("ECH_B64", "")
out_dir = os.environ["OUT_DIR"]
cdn = os.environ.get("CDN_ADDRESS", "").strip()
addr = cdn or host          # what the client dials
xmode = os.environ.get("XHTTP_MODE", "packet-up")
if xmode not in ("auto", "packet-up", "stream-up", "stream-one"):
    xmode = "packet-up"

PROTOS = [
    # proto,   ws path,        tag
    ("vless",  "/vless-saeka",  "vless"),
    ("trojan", "/saeka-tojirp", "trojan"),
    ("vmess",  "/vmess-saeka",  "vmess"),
    ("ss",     "/ss-saeka",     "ss"),
]

# Reuse settings for xHTTP connections. hMaxReusableSecs is kept well under
# Cloud Run's 3600s request cap so a connection is retired and replaced by the
# client before the platform cuts it mid-transfer.
XMUX = {
    "maxConcurrency": "16-32",
    "maxConnections": 0,
    "cMaxReuseTimes": 0,
    "hMaxRequestTimes": "600-900",
    "hMaxReusableSecs": "1800-3000",
    "hKeepAlivePeriod": 0,
}

q = urllib.parse.quote


def transport_query(path, kind="ws"):
    parts = [
        ("security", "tls"), ("sni", host), ("fp", fp),
        ("type", kind), ("host", host), ("path", path),
    ]
    if kind == "xhttp":
        parts.append(("mode", xmode))
    if ech:
        parts.append(("ech", ech))
    return "&".join(f"{k}={q(v, safe='')}" for k, v in parts)


def share_link(proto, path, label, kind="ws"):
    tq = transport_query(path, kind)
    if proto == "vless":
        return f"vless://{q(uid, safe='')}@{addr}:{port}?encryption=none&{tq}#{label}"
    if proto == "trojan":
        return f"trojan://{q(uid, safe='')}@{addr}:{port}?{tq}#{label}"
    if proto == "vmess":
        # vmess:// is base64 of a JSON object (v2rayN format), not a normal URI.
        obj = {
            "v": "2", "ps": label, "add": addr, "port": str(port), "id": uid,
            "aid": "0", "scy": "auto", "net": "ws", "type": "none",
            "host": host, "path": path, "tls": "tls", "sni": host, "fp": fp, "alpn": "",
        }
        return "vmess://" + base64.b64encode(json.dumps(obj).encode()).decode()
    if proto == "ss":
        # ss:// userinfo is base64(method:password), then host:port and query.
        userinfo = base64.urlsafe_b64encode(f"aes-256-gcm:{uid}".encode()).decode().rstrip("=")
        return f"ss://{userinfo}@{addr}:{port}?{tq}#{label}"


def outbound(proto, path, tag, kind="ws"):
    if proto == "vless":
        settings = {"vnext": [{"address": addr, "port": port,
                               "users": [{"id": uid, "encryption": "none"}]}]}
    elif proto == "vmess":
        settings = {"vnext": [{"address": addr, "port": port,
                               "users": [{"id": uid, "alterId": 0, "security": "auto"}]}]}
    elif proto == "trojan":
        settings = {"servers": [{"address": addr, "port": port, "password": uid}]}
    else:  # ss
        settings = {"servers": [{"address": addr, "port": port,
                                 "method": "aes-256-gcm", "password": uid}]}
    tls = {"serverName": host, "fingerprint": fp}
    if ech:
        tls["echConfigList"] = ech
    if pin:
        tls["pinnedPeerCertificateChainSha256"] = [pin]
    stream = {"network": kind, "security": "tls", "tlsSettings": tls}
    if kind == "xhttp":
        stream["xhttpSettings"] = {"host": host, "path": path, "mode": xmode, "xmux": XMUX}
    else:
        stream["wsSettings"] = {"path": path, "host": host}
    return {
        "tag": f"saeka-{tag}" + ("-xhttp" if kind == "xhttp" else ""),
        "protocol": "shadowsocks" if proto == "ss" else proto,
        "settings": settings,
        "streamSettings": stream,
    }


links = []
for proto, path, tag in PROTOS:
    links.append(share_link(proto, path, f"saeka-{tag}-ws"))
    jf = os.path.join(out_dir, f"{host}-{tag}-outbound.json")
    with open(jf, "w") as fh:
        json.dump({"outbounds": [outbound(proto, path, tag)]}, fh, indent=2)
        fh.write("\n")
    print(f"[+] Xray outbound ({proto}, ws): {jf}")

    # xHTTP twin of every protocol (server path = <ws path>-xh)
    xpath = path + "-xh"
    if proto in ("vless", "trojan"):
        links.append(share_link(proto, xpath, f"saeka-{tag}-xhttp", "xhttp"))
    xf = os.path.join(out_dir, f"{host}-{tag}-xhttp-outbound.json")
    with open(xf, "w") as fh:
        json.dump({"outbounds": [outbound(proto, xpath, tag, "xhttp")]}, fh, indent=2)
        fh.write("\n")
    print(f"[+] Xray outbound ({proto}, xhttp {xmode}): {xf}")

with open(os.environ["LINKS_FILE"], "w") as fh:
    fh.write("\n".join(links) + "\n")

if cdn:
    print(f"\n[+] CDN mode: dialing {cdn}:{port}, SNI/Host = {host}")
print("\n[+] Share links:")
print("\n".join(links))
PY

# --- Raw-TCP masked transport: not in the share links above (no TLS, no
# path - it's a direct listener, only reachable on GCE/GKE, never Cloud Run).
if [ -n "${TCP_RAW_HOST:-}" ]; then
    TCP_RAW_JSON="./client-links/${HOST}-rawtcp-outbound.json"
    cat > "$TCP_RAW_JSON" << EOF
{
  "outbounds": [{
    "protocol": "${TCP_RAW_PROTOCOL:-vless}",
    "settings": {
      "vnext": [{
        "address": "${TCP_RAW_HOST}",
        "port": ${TCP_RAW_PORT:-20002},
        "users": [{"id": "${USERID}", "encryption": "none"}]
      }]
    },
    "streamSettings": {
      "network": "tcp",
      "security": "none",
      "tcpSettings": {"header": {"type": "${TCP_RAW_MASK:-http}"}}
    }
  }]
}
EOF
    echo "[+] Raw-TCP client outbound: ${TCP_RAW_JSON}"
fi

echo ""
echo "[i] vmess/ss have xHTTP outbound JSON only (no standard share-link form)."
echo "[i] Using a non-UUID id like 'saeka' works with Xray itself, but some mobile"
echo "    clients insist on a UUID for vless/vmess. If an app rejects the link,"
echo "    switch to the trojan or ss link, or change the id in common/config-*.json."
