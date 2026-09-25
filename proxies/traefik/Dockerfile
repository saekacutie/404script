# docker build -f proxies/traefik/Dockerfile -t IMAGE .
# traefik:v3.1 already has traefik itself; we only add xray.
FROM alpine:3.20 AS xray-fetch
RUN apk add --no-cache curl unzip ca-certificates
RUN curl -fsSL -o /tmp/xray.zip \
        https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip \
    && unzip -q /tmp/xray.zip -d /out \
    && chmod +x /out/xray

FROM traefik:v3.1
USER root
RUN apk add --no-cache bash ca-certificates

COPY --from=xray-fetch /out/xray /usr/local/bin/xray
RUN mkdir -p /etc/xray
COPY common/config-ads.json   /etc/xray/config-ads.json
COPY common/config-noads.json /etc/xray/config-noads.json
RUN mkdir -p /etc/traefik
COPY proxies/traefik/traefik.yml /etc/traefik/traefik.yml
RUN mkdir -p /etc/traefik
COPY proxies/traefik/dynamic.yml /etc/traefik/dynamic.yml
COPY proxies/traefik/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 8080
ENTRYPOINT ["/entrypoint.sh"]
