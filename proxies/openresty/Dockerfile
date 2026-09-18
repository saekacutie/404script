# docker build -f proxies/openresty/Dockerfile -t IMAGE .
FROM alpine:3.20 AS xray-fetch
RUN apk add --no-cache curl unzip ca-certificates
RUN curl -fsSL -o /tmp/xray.zip https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip \
    && unzip -q /tmp/xray.zip -d /out && chmod +x /out/xray \
    && curl -fsSL -o /out/geosite.dat https://github.com/2dust/v2ray-rules-dat/releases/latest/download/geosite.dat
FROM openresty/openresty:1.25.3.1-alpine
RUN apk add --no-cache bash ca-certificates
COPY --from=xray-fetch /out/xray /usr/local/bin/xray
COPY --from=xray-fetch /out/geosite.dat /usr/local/share/xray/geosite.dat
RUN mkdir -p /etc/xray /usr/local/share/xray
COPY common/config-ads.json /etc/xray/config-ads.json
COPY common/config-noads.json /etc/xray/config-noads.json
COPY common/ads-mode.sh /ads-mode.sh
COPY common/index.html /usr/local/openresty/nginx/html/index.html
COPY proxies/openresty/nginx.conf /usr/local/openresty/nginx/conf/nginx.conf
COPY proxies/openresty/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh /ads-mode.sh
EXPOSE 8080
ENTRYPOINT ["/entrypoint.sh"]
