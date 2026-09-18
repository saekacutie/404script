# docker build -f proxies/envoy/Dockerfile -t IMAGE .
FROM alpine:3.20 AS xray-fetch
RUN apk add --no-cache curl unzip ca-certificates
RUN curl -fsSL -o /tmp/xray.zip \
        https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip \
    && unzip -q /tmp/xray.zip -d /out \
    && chmod +x /out/xray \
    && curl -fsSL -o /out/geosite.dat \
        https://github.com/2dust/v2ray-rules-dat/releases/latest/download/geosite.dat

FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends \
        curl gnupg ca-certificates \
    && curl -fsSL https://apt.envoyproxy.io/signing.key | gpg --dearmor -o /etc/apt/trusted.gpg.d/envoy.gpg \
    && echo "deb [arch=amd64,arm64 signed-by=/etc/apt/trusted.gpg.d/envoy.gpg] https://apt.envoyproxy.io bookworm main" \
        > /etc/apt/sources.list.d/envoy.list \
    && apt-get update && apt-get install -y --no-install-recommends envoy \
    && apt-get purge -y gnupg && apt-get autoremove -y \
    && apt-get clean && rm -rf /var/lib/apt/lists/*
COPY --from=xray-fetch /out/xray /usr/local/bin/xray
COPY --from=xray-fetch /out/geosite.dat /usr/local/share/xray/geosite.dat
RUN mkdir -p /etc/xray /etc/envoy /usr/local/share/xray
COPY common/config-ads.json /etc/xray/config-ads.json
COPY common/config-noads.json /etc/xray/config-noads.json
COPY common/ads-mode.sh /ads-mode.sh
COPY proxies/envoy/envoy.yaml /etc/envoy/envoy.yaml
COPY proxies/envoy/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh /ads-mode.sh
EXPOSE 8080
ENTRYPOINT ["/entrypoint.sh"]
