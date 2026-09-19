# docker build -f proxies/envoy/Dockerfile -t IMAGE .
FROM alpine:3.20 AS xray-fetch
RUN apk add --no-cache curl unzip ca-certificates
RUN curl -fsSL -o /tmp/xray.zip \
        https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip \
    && unzip -q /tmp/xray.zip -d /out \
    && chmod +x /out/xray

FROM debian:bookworm-slim
RUN apt-get update \
    && apt-get install -y --no-install-recommends curl gnupg ca-certificates bash \
    && curl -fsSL https://apt.envoyproxy.io/signing.key | gpg --dearmor -o /etc/apt/keyrings/envoy-keyring.gpg \
    && echo "deb [signed-by=/etc/apt/keyrings/envoy-keyring.gpg] https://apt.envoyproxy.io bookworm main" \
        > /etc/apt/sources.list.d/envoy.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends envoy \
    && rm -rf /var/lib/apt/lists/*
COPY --from=xray-fetch /out/xray /usr/local/bin/xray
RUN mkdir -p /etc/xray /etc/envoy
COPY common/config-ads.json   /etc/xray/config-ads.json
COPY common/config-noads.json /etc/xray/config-noads.json
COPY proxies/envoy/envoy.yaml /etc/envoy/envoy.yaml
COPY common/ssh-install.sh /tmp/ssh-install.sh
COPY common/ssh-ws.sh /usr/local/bin/ssh-ws.sh
RUN bash /tmp/ssh-install.sh && rm -f /tmp/ssh-install.sh && chmod +x /usr/local/bin/ssh-ws.sh
COPY proxies/envoy/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 8080
ENTRYPOINT ["/entrypoint.sh"]
