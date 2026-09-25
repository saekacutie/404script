# docker build -f proxies/caddy/Dockerfile -t IMAGE .
# caddy:2-alpine already has caddy itself; we only add xray.
FROM alpine:3.20 AS xray-fetch
RUN apk add --no-cache curl unzip ca-certificates
RUN curl -fsSL -o /tmp/xray.zip \
        https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip \
    && unzip -q /tmp/xray.zip -d /out \
    && chmod +x /out/xray

FROM caddy:2-alpine
USER root
RUN apk add --no-cache bash ca-certificates

COPY --from=xray-fetch /out/xray /usr/local/bin/xray
RUN mkdir -p /etc/xray
COPY common/config-ads.json   /etc/xray/config-ads.json
COPY common/config-noads.json /etc/xray/config-noads.json
RUN mkdir -p /etc/caddy
COPY proxies/caddy/Caddyfile /etc/caddy/Caddyfile
COPY proxies/caddy/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 8080
ENTRYPOINT ["/entrypoint.sh"]
