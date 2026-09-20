# docker build -f proxies/ovpn-relay/Dockerfile -t IMAGE .
#
# This does NOT run OpenVPN. Cloud Run's sandbox refuses /dev/net/tun and
# CAP_NET_ADMIN unconditionally, and an OpenVPN server needs both to
# create its TUN interface - no image, config, or trick changes that.
#
# What this actually is: a WS-camouflaged relay. It accepts a WS-looking
# connection at /saeka-ovpn on your run.app URL and forwards the raw
# bytes to a REAL OpenVPN server (proto tcp) on a VM (see deploy_vm.py).
# /cert serves the client .ovpn behind a login (SSH_USERS).
FROM debian:bookworm-slim
ENV DEBIAN_FRONTEND=noninteractive

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
