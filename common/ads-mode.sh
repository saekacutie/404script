#!/bin/bash
# Build and validate the Xray profile used by every proxy engine.
# Domain blocking is enforced in routing (not only DNS hosts), so proxied
# requests to matching ad/tracker domains reach the blackhole outbound.
set -euo pipefail

ADS_MODE="${ADS_MODE:-noads}"
ADS_LEVEL="${ADS_LEVEL:-standard}"
CONFIG=/etc/xray/config.json
ASSET_DIR="${XRAY_LOCATION_ASSET:-/usr/local/share/xray}"

case "$ADS_MODE" in
  ads)
    cp /etc/xray/config-ads.json "$CONFIG"
    ;;
  noads)
    cp /etc/xray/config-noads.json "$CONFIG"
    case "$ADS_LEVEL" in
      light)
        DOMAINS='"geosite:category-ads"'
        ;;
      standard)
        DOMAINS='"geosite:category-ads-all"'
        ;;
      strict)
        DOMAINS='"geosite:category-ads-all","geosite:category-tracking"'
        ;;
      extreme)
        # Keep the extreme profile focused on ad/tracker families. Blocking
        # malware/phishing here would be a different security policy and can
        # unexpectedly deny legitimate security and update endpoints.
        DOMAINS='"geosite:category-ads-all","geosite:category-tracking"'
        ;;
      *)
        echo "[!] Unknown ADS_LEVEL=$ADS_LEVEL; using standard" >&2
        ADS_LEVEL=standard
        DOMAINS='"geosite:category-ads-all"'
        ;;
    esac
    # Shadowsocks entries in the legacy profiles lacked sniffing, so add it
    # before the settings property. This is idempotent because the source is
    # copied fresh on every start.
    sed -i -E '/"tag": "ss-(ws|hu|xh|grpc)",/a\        "sniffing": {"enabled": true, "destOverride": ["http", "tls"]},' "$CONFIG"
    # Insert the block rule before the existing direct catch-all rule.
    sed -i "s|\"rules\": \[|\"rules\": [{\"type\":\"field\",\"domain\":[$DOMAINS],\"outboundTag\":\"block\"},|" "$CONFIG"
    ;;
  *)
    echo "[!] Invalid ADS_MODE=$ADS_MODE; refusing to start" >&2
    exit 2
    ;;
esac

export XRAY_LOCATION_ASSET="$ASSET_DIR"
# Validate both JSON structure and Xray-specific routing/assets before launch.
if ! command -v xray >/dev/null 2>&1; then
  echo "[!] xray is not installed" >&2
  exit 127
fi
xray run -test -config "$CONFIG"
echo "[+] Ads mode: $ADS_MODE (level: ${ADS_LEVEL:-off})"
