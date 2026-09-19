# docker build -f proxies/openresty/Dockerfile -t IMAGE .
# NOTE: this engine cannot serve gRPC (see comment at the top of nginx.conf) -
# it only does WS / HTTPUpgrade / XHTTP.
FROM alpine:3.20 AS xray-fetch
RUN apk add --no-cache curl unzip ca-certificates
RUN curl -fsSL -o /tmp/xray.zip \
        https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip \
    && unzip -q /tmp/xray.zip -d /out \
    && chmod +x /out/xray

FROM openresty/openresty:alpine
# Rolling `alpine` tag instead of a pinned patch version
# (`1.25.3.1-alpine` etc.) for the same reason as HAProxy above - pinned
# patch tags are the most likely cause of a sudden build failure here.
# Pin an exact version once confirmed current:
# https://hub.docker.com/r/openresty/openresty/tags
RUN apk add --no-cache bash ca-certificates
COPY --from=xray-fetch /out/xray /usr/local/bin/xray
RUN mkdir -p /etc/xray
COPY common/config-ads.json   /etc/xray/config-ads.json
COPY common/config-noads.json /etc/xray/config-noads.json
COPY common/index.html /usr/local/openresty/nginx/html/index.html
COPY proxies/openresty/nginx.conf /usr/local/openresty/nginx/conf/nginx.conf
COPY proxies/openresty/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 8080
ENTRYPOINT ["/entrypoint.sh"]
