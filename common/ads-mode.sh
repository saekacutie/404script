#!/bin/bash
# Shared Xray ad policy loader for every proxy engine.
# ADS_MODE=ads disables blocking. ADS_MODE=noads enables the selected policy.
# ADS_LEVEL: light, standard, strict, extreme.
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
      light)    DOMAINS='"geosite:category-ads"' ;;
      standard) DOMAINS='"geosite:category-ads-all"' ;;
      strict)   DOMAINS='"geosite:category-ads-all","geosite:category-tracking"' ;;
      extreme)  DOMAINS='"geosite:category-ads-all","geosite:category-tracking","geosite:category-social"' ;;
      *)
        echo "[!] Invalid ADS_LEVEL=$ADS_LEVEL; using standard" >&2
        ADS_LEVEL=standard
        DOMAINS='"geosite:category-ads-all"'
        ;;
    esac
    # Add sniffing to Shadowsocks in the legacy template so Xray can identify
    # the destination domain for those inbound transports as well.
    sed -i -E '/"tag": "ss-(ws|hu|xh|grpc)",/a\        "sniffing": {"enabled": true, "destOverride": ["http", "tls"]},' "$CONFIG"
    # This is deliberately inserted before the existing direct rule.
    sed -i "s|\"rules\": \[|\"rules\": [{\"type\":\"field\",\"domain\":[$DOMAINS],\"outboundTag\":\"block\"},|" "$CONFIG"
    ;;
  *)
    echo "[!] Invalid ADS_MODE=$ADS_MODE; refusing to start" >&2
    exit 2
    ;;
esac

export XRAY_LOCATION_ASSET="$ASSET_DIR"
command -v xray >/dev/null 2>&1 || { echo '[!] xray is not installed' >&2; exit 127; }
# Validate generated JSON, routing order, and geosite references before launch.
xray run -test -config "$CONFIG"
echo "[+] Ads mode: $ADS_MODE (level: ${ADS_LEVEL:-off})"
