# docker build -f proxies/openresty/Dockerfile -t IMAGE .
FROM alpine:3.20 AS xray-fetch
RUN apk add --no-cache curl unzip ca-certificates
RUN curl -fsSL -o /tmp/xray.zip \
        https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip \
    && unzip -q /tmp/xray.zip -d /out \
    && chmod +x /out/xray

FROM openresty/openresty:1.25.3.1-alpine
RUN apk add --no-cache bash ca-certificates
COPY --from=xray-fetch /out/xray /usr/local/bin/xray
RUN mkdir -p /etc/xray
COPY common/config-ads.json   /etc/xray/config-ads.json
COPY common/config-noads.json /etc/xray/config-noads.json
COPY common/index.html /usr/local/openresty/nginx/html/index.html
COPY proxies/openresty/nginx.conf /usr/local/openresty/nginx/conf/nginx.conf
COPY common/ssh-install.sh /tmp/ssh-install.sh
COPY common/ssh-ws.sh /usr/local/bin/ssh-ws.sh
RUN sh /tmp/ssh-install.sh && rm -f /tmp/ssh-install.sh && chmod +x /usr/local/bin/ssh-ws.sh
COPY proxies/openresty/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 8080
ENTRYPOINT ["/entrypoint.sh"]
