#!/bin/bash
# Select the Xray profile and add a maintained geosite ad/tracker rule in no-ads mode.
# DNS hosts alone do not block proxied traffic: Xray must route matching domains
# to its blackhole outbound before the catch-all direct rule.
set -e

ADS_MODE="${ADS_MODE:-noads}"
if [ "$ADS_MODE" = "ads" ]; then
    cp /etc/xray/config-ads.json /etc/xray/config.json
else
    cp /etc/xray/config-noads.json /etc/xray/config.json
    # Insert before the existing catch-all direct rule. The config is copied on
    # every start, so this remains idempotent across watchdog restarts.
    sed -i 's|"rules": \[|"rules": [\n      { "type": "field", "domain": ["geosite:category-ads-all"], "outboundTag": "block" },|' /etc/xray/config.json
fi

export XRAY_LOCATION_ASSET="${XRAY_LOCATION_ASSET:-/usr/local/share/xray}"
echo "[+] Ads mode: $ADS_MODE"
