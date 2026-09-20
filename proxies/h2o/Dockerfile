# docker build -f proxies/h2o/Dockerfile -t IMAGE .
# Plain Alpine base - h2o itself comes from the apk repo, same as xray/ssh.
FROM alpine:3.20 AS xray-fetch
RUN apk add --no-cache curl unzip ca-certificates
RUN curl -fsSL -o /tmp/xray.zip \
        https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip \
    && unzip -q /tmp/xray.zip -d /out \
    && chmod +x /out/xray

FROM alpine:3.20
USER root
RUN apk add --no-cache bash openssh openssh-server shadow ca-certificates h2o

COPY --from=xray-fetch /out/xray /usr/local/bin/xray
RUN mkdir -p /etc/xray
COPY common/config-ads.json   /etc/xray/config-ads.json
COPY common/config-noads.json /etc/xray/config-noads.json
RUN mkdir -p /etc/h2o
COPY proxies/h2o/h2o.conf /etc/h2o/h2o.conf
COPY proxies/h2o/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 8080
ENTRYPOINT ["/entrypoint.sh"]
