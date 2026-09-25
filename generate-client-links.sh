#!/bin/bash
# ==============================================================================
# CLIENT LINK / CONFIG GENERATOR
# ==============================================================================
# ECH config list and certificate SHA-256 pinning are NOT server-side Xray
# settings in this stack. The server inbounds here listen on plaintext
# 127.0.0.1 - TLS is terminated upstream of Xray entirely (by Cloud Run's
# managed cert, or by whatever fronts your GCE/GKE deploy). There is no
# TLS handshake inside the container for ECH or pinning to attach to.
#
# Both settings are properties of the CLIENT's TLS dial to whatever host:port
# it connects to:
#   - fp (uTLS fingerprint)  shapes the client's ClientHello to look like a
#     real browser, independent of who terminates TLS on the other end.
#   - ECH config list         comes from a DNS HTTPS/SVCB record published for
#     the domain, and tells the client how to encrypt its SNI in that hello.
#   - pinned cert SHA-256     is the client checking the actual leaf cert it
#     gets back matches what you expect (defends against a MITM presenting a
#     different, still-valid cert for the same name).
# All three are genuine anti-DPI / anti-MITM protections, they just apply on
# the client's outbound TLS dial, not on the server JSON you asked me to add
# them to.
#
# NOTE ALSO: certificate pinning has no defined slot in the informal
# vless://, vmess://, trojan:// share-link formats, and ECH-in-URI is only
# understood by a handful of very recent xray-based clients. This script
# therefore emits BOTH a share-link (best-effort, works everywhere for
# fp+sni) AND a full JSON outbound config (authoritative, supports pinning
# and ECH reliably in any Xray/V2Ray-core-based client).
# ==============================================================================
set -e

HOST="${1:?Usage: $0 <host> [port] [uuid_or_password] [fp]}"
PORT="${2:-443}"
USERID="${3:-saeka}"
FP="${4:-chrome}"   # chrome | firefox | safari | ios | android | edge | random
FRAGMENT_MODE="${FRAGMENT_MODE:-n}"  # y enables Xray TLS ClientHello fragmentation in JSON output

case "$FP" in
    chrome|firefox|safari|ios|android|edge|random|randomized) ;;
    *) echo "[-] Unknown fp '$FP', falling back to chrome"; FP="chrome";;
esac

TLS_FRAGMENT_FIELDS=""
case "$FRAGMENT_MODE" in
    [Yy])
        TLS_FRAGMENT_FIELDS=',
      "fragment": {"packets": "tlshello", "length": "100-200", "interval": "10-20"}'
        echo "[+] TLS ClientHello fragmentation: enabled in authoritative JSON output"
        ;;
    [Nn]) ;;
    *) echo "[-] FRAGMENT_MODE must be y or n; using n"; FRAGMENT_MODE="n";;
esac

echo "[+] Probing ${HOST}:${PORT} for its live certificate (best-effort)..."
CERT_SHA256_B64=""
if command -v openssl >/dev/null 2>&1; then
    CERT_SHA256_B64=$(echo | timeout 5 openssl s_client -connect "${HOST}:${PORT}" -servername "${HOST}" 2>/dev/null \
        | openssl x509 -outform DER 2>/dev/null | openssl dgst -sha256 -binary | base64) || true
fi
if [ -z "$CERT_SHA256_B64" ]; then
    echo "[-] Could not fetch a live cert (host not up yet, or openssl missing). Pin left blank - re-run once the service is live."
fi

echo "[+] Looking up ECH config for ${HOST} via DNS HTTPS record (best-effort)..."
ECH_B64=""
if command -v dig >/dev/null 2>&1; then
    ECH_B64=$(dig +short HTTPS "${HOST}" 2>/dev/null | grep -o 'ech=[^ "]*' | head -1 | cut -d= -f2) || true
fi
if [ -z "$ECH_B64" ]; then
    echo "[-] No ECH record found (most domains don't publish one, and Cloud Run's default domain won't). Pass your own with ECH_OVERRIDE=<base64> if you have it."
fi
ECH_B64="${ECH_OVERRIDE:-$ECH_B64}"

urlenc() { python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=''))" "$1"; }

mkdir -p ./client-links
LINKS_FILE="./client-links/${HOST}-links.txt"
: > "$LINKS_FILE"

emit_link() {
    local proto="$1" path="$2" label="$3"
    local q="encryption=none&security=tls&sni=${HOST}&fp=${FP}&type=ws&host=${HOST}&path=$(urlenc "$path")"
    [ -n "$ECH_B64" ] && q="${q}&ech=$(urlenc "$ECH_B64")"
    echo "${proto}://${USERID}@${HOST}:${PORT}?${q}#${label}" >> "$LINKS_FILE"
}

emit_link "vless"  "/vless-saeka"   "saeka-vless-ws"
emit_link "trojan" "/saeka-tojirp"  "saeka-trojan-ws"

echo "[+] Share links (fp+sni, ECH if found - see file header re: pinning support in URIs):"
cat "$LINKS_FILE"

# Authoritative JSON outbound - the only place pinning is guaranteed to work.
JSON_FILE="./client-links/${HOST}-outbound.json"
cat > "$JSON_FILE" << EOF
{
  "_comment": "Client-side outbound. fp/ech/pinning all apply here, on the TLS dial to ${HOST}:${PORT} - none of these are server config.",
  "protocol": "vless",
  "settings": {
    "vnext": [{
      "address": "${HOST}",
      "port": ${PORT},
      "users": [{"id": "${USERID}", "encryption": "none"}]
    }]
  },
  "streamSettings": {
    "network": "ws",
    "security": "tls",
    "wsSettings": {"path": "/vless-saeka", "host": "${HOST}"},
    "tlsSettings": {
      "serverName": "${HOST}",
      "fingerprint": "${FP}"${TLS_FRAGMENT_FIELDS},
      $( [ -n "$ECH_B64" ] && echo "\"echConfigList\": \"${ECH_B64}\"," )
      "pinnedPeerCertificateChainSha256": [$( [ -n "$CERT_SHA256_B64" ] && echo "\"${CERT_SHA256_B64}\"" )]
    }
  }
}
EOF
echo ""
echo "[+] Authoritative client outbound (pinning + ECH guaranteed): ${JSON_FILE}"
[ -z "$CERT_SHA256_B64" ] && echo "[!] pinnedPeerCertificateChainSha256 is empty - fill it in once you have a live cert to probe, or the client will just skip pinning."

# --- Raw-TCP masked transport: not in the share links above (no TLS, no
# path - it's a direct listener, only reachable on GCE/GKE, never Cloud
# Run). Add it to the client manually with these fields.
if [ -n "$TCP_RAW_HOST" ]; then
    TCP_RAW_JSON="./client-links/${HOST}-rawtcp-outbound.json"
    cat > "$TCP_RAW_JSON" << EOF
{
  "_comment": "Raw TCP masked transport - point at the GCE/GKE host directly, NOT ${HOST}. No TLS applies here.",
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
}
EOF
    echo "[+] Raw-TCP client outbound (fill in address/port/protocol to match what you enabled in deploy.sh): ${TCP_RAW_JSON}"
fi
