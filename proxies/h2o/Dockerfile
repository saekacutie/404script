# docker build -f proxies/h2o/Dockerfile -t IMAGE .
# H2O is the least battle-tested engine here (same caveat the original repo
# flagged). If `apk add h2o` isn't available for the Alpine tag you're on,
# swap this stage to build from source (git clone h2o/h2o + cmake + ninja)
# the way the old single-Dockerfile setup did for this engine only -
# you no longer pay that build cost for the other 5 engines.
FROM alpine:3.20 AS xray-fetch
RUN apk add --no-cache curl unzip ca-certificates
RUN curl -fsSL -o /tmp/xray.zip \
        https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip \
    && unzip -q /tmp/xray.zip -d /out \
    && chmod +x /out/xray

FROM alpine:3.20
RUN apk add --no-cache bash ca-certificates h2o
COPY --from=xray-fetch /out/xray /usr/local/bin/xray
RUN mkdir -p /etc/xray /etc/h2o /var/www/html \
    && echo OK > /var/www/html/health
COPY common/config-ads.json   /etc/xray/config-ads.json
COPY common/config-noads.json /etc/xray/config-noads.json
COPY proxies/h2o/h2o.conf /etc/h2o/h2o.conf
COPY proxies/h2o/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 8080
ENTRYPOINT ["/entrypoint.sh"]
