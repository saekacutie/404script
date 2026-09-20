# docker build -f proxies/ovpn-relay/Dockerfile -t IMAGE .
# WebSocket-style front door on Cloud Run that forwards raw TCP to a real
# OpenVPN server (proto tcp) on a VM. Cloud Run cannot run OpenVPN itself
# (no /dev/net/tun, no CAP_NET_ADMIN).
FROM debian:bookworm-slim
ARG DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
        nginx python3 \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

COPY proxies/ovpn-relay/nginx.conf /etc/nginx/nginx.conf
COPY proxies/ovpn-relay/ws_bridge.py /opt/ws_bridge.py
COPY proxies/ovpn-relay/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 8080
ENTRYPOINT ["/entrypoint.sh"]
