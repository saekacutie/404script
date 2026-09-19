# Build context = repo root. Build with:
#   docker build -f proxies/haproxy/Dockerfile -t IMAGE .
# Only pulls HAProxy + Xray - no other engine is downloaded or installed.

FROM alpine:3.20 AS xray-fetch
RUN apk add --no-cache curl unzip ca-certificates
RUN curl -fsSL -o /tmp/xray.zip \
        https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip \
    && unzip -q /tmp/xray.zip -d /out \
    && chmod +x /out/xray

FROM haproxy:alpine
# Using the rolling `alpine` tag instead of a pinned patch version
# (`2.9-alpine` etc.) - those get pruned off Docker Hub over time and are
# the single most likely reason this engine specifically stopped
# building. Pin an exact version again once you've confirmed what's
# current: https://hub.docker.com/_/haproxy/tags
USER root
RUN apk add --no-cache bash ca-certificates
COPY --from=xray-fetch /out/xray /usr/local/bin/xray
RUN mkdir -p /etc/xray
COPY common/config-ads.json   /etc/xray/config-ads.json
COPY common/config-noads.json /etc/xray/config-noads.json
COPY proxies/haproxy/haproxy.cfg /usr/local/etc/haproxy/haproxy.cfg
COPY proxies/haproxy/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 8080
ENTRYPOINT ["/entrypoint.sh"]
