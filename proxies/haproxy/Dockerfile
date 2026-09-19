# docker build -f proxies/haproxy/Dockerfile -t IMAGE .
FROM alpine:3.20 AS xray-fetch
RUN apk add --no-cache curl unzip ca-certificates
RUN curl -fsSL -o /tmp/xray.zip \
        https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip \
    && unzip -q /tmp/xray.zip -d /out \
    && chmod +x /out/xray

FROM haproxy:2.9-alpine
USER root
RUN apk add --no-cache bash ca-certificates
COPY --from=xray-fetch /out/xray /usr/local/bin/xray
RUN mkdir -p /etc/xray /usr/local/etc/haproxy
COPY common/config-ads.json   /etc/xray/config-ads.json
COPY common/config-noads.json /etc/xray/config-noads.json
COPY proxies/haproxy/haproxy.cfg /usr/local/etc/haproxy/haproxy.cfg
COPY common/ssh-install.sh /tmp/ssh-install.sh
COPY common/ssh-ws.sh /usr/local/bin/ssh-ws.sh
RUN sh /tmp/ssh-install.sh && rm -f /tmp/ssh-install.sh && chmod +x /usr/local/bin/ssh-ws.sh
COPY proxies/haproxy/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 8080
ENTRYPOINT ["/entrypoint.sh"]
