# docker build -f proxies/h2o/Dockerfile -t IMAGE .
FROM alpine:3.20 AS xray-fetch
RUN apk add --no-cache curl unzip ca-certificates
RUN curl -fsSL -o /tmp/xray.zip https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip \
    && unzip -q /tmp/xray.zip -d /out && chmod +x /out/xray \
    && curl -fsSL -o /out/geosite.dat https://github.com/2dust/v2ray-rules-dat/releases/latest/download/geosite.dat
FROM alpine:3.20
RUN apk add --no-cache bash ca-certificates h2o
COPY --from=xray-fetch /out/xray /usr/local/bin/xray
COPY --from=xray-fetch /out/geosite.dat /usr/local/share/xray/geosite.dat
RUN mkdir -p /etc/xray /etc/h2o /usr/local/share/xray /var/www/html && echo OK > /var/www/html/health
COPY common/config-ads.json /etc/xray/config-ads.json
COPY common/config-noads.json /etc/xray/config-noads.json
COPY common/ads-mode.sh /ads-mode.sh
COPY proxies/h2o/h2o.conf /etc/h2o/h2o.conf
COPY proxies/h2o/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh /ads-mode.sh
EXPOSE 8080
ENTRYPOINT ["/entrypoint.sh"]
