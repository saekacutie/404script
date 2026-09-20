# docker build -f proxies/ovpn-relay/Dockerfile -t IMAGE .
# nginx :8080 -> ws_bridge :2223 -> OpenVPN VM (OVPN_UPSTREAM_HOST)
# Optional: /cert -> cert_server :2224 (login = SSH_USERS) serves the .ovpn
# Standalone: no SSH here - see proxies/ssh for the SSH-over-WS engine.
FROM debian:bookworm-slim
ARG DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
        nginx python3 ca-certificates \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

COPY proxies/ovpn-relay/nginx.conf /etc/nginx/nginx.conf
COPY proxies/common/ws_bridge.py /opt/ws_bridge.py
COPY proxies/common/cert_server.py /opt/cert_server.py
COPY proxies/ovpn-relay/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 8080
ENTRYPOINT ["/entrypoint.sh"]
