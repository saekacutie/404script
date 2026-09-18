#!/bin/bash
# Build an Xray config with an explicit ad/tracker routing policy.
# DNS hosts are not sufficient for proxied traffic: matching domains must be
# sent to Xray's blackhole outbound before the catch-all direct rule.
set -euo pipefail

ADS_MODE="${ADS_MODE:-noads}"
ADS_LEVEL="${ADS_LEVEL:-standard}"
CONFIG=/etc/xray/config.json

if [ "$ADS_MODE" = "ads" ]; then
    cp /etc/xray/config-ads.json "$CONFIG"
else
    cp /etc/xray/config-noads.json "$CONFIG"
    case "$ADS_LEVEL" in
        light)
            RULE='{"type":"field","domain":["geosite:category-ads"],"outboundTag":"block"}'
            ;;
        standard)
            RULE='{"type":"field","domain":["geosite:category-ads-all"],"outboundTag":"block"}'
            ;;
        strict)
            RULE='{"type":"field","domain":["geosite:category-ads-all","geosite:category-tracking"],"outboundTag":"block"}'
            ;;
        extreme)
            RULE='{"type":"field","domain":["geosite:category-ads-all","geosite:category-tracking","geosite:category-malware","geosite:category-phishing"],"outboundTag":"block"}'
            ;;
        *)
            echo "[!] Unknown ADS_LEVEL=$ADS_LEVEL; using standard" >&2
            ADS_LEVEL=standard
            RULE='{"type":"field","domain":["geosite:category-ads-all"],"outboundTag":"block"}'
            ;;
    esac
    # The source template is copied fresh above, so this is idempotent.
    sed -i "s|\"rules\": \[|\"rules\": [$RULE,|" "$CONFIG"
fi

export XRAY_LOCATION_ASSET="${XRAY_LOCATION_ASSET:-/usr/local/share/xray}"
# Fail before starting the proxy if the generated JSON or geosite policy is bad.
xray run -test -config "$CONFIG"
echo "[+] Ads mode: $ADS_MODE (level: $ADS_LEVEL)"
