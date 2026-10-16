# docker build -f proxies/ovpn-relay/Dockerfile -t saeka-ovpn-relay .
FROM debian:bookworm-slim

ARG DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
        nginx python3 python3-websockets ca-certificates \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

COPY proxies/ovpn-relay/nginx.conf /etc/nginx/nginx.conf
COPY proxies/common/ws_bridge.py /opt/ws_bridge.py
COPY proxies/common/cert_server.py /opt/cert_server.py
COPY proxies/ovpn-relay/entrypoint.sh /entrypoint.sh

RUN chmod +x /entrypoint.sh

EXPOSE 8080
ENTRYPOINT ["/entrypoint.sh"]
