# docker build -f proxy/reality/Dockerfile -t IMAGE .
#
# Cloud Run half of the "Reality Combo" engine. One nginx on :8080 fronts:
#   /saeka-ssh   -> ws_bridge :2222 -> Dropbear :2200      (SSH over WS, user:pass)
#                   badvpn-udpgw :7300 carries UDP through the SSH tunnel
#   /saeka-ovpn  -> ws_bridge :2223 -> OpenVPN VM (tcp)    (only if OVPN_UPSTREAM_HOST)
#   /cert        -> cert_server :2224                      (OpenVPN profile, basic auth)
#   XHTTP path   -> https://VM:8443 (pinned self-signed)   (only if XHTTP_UPSTREAM_HOST)
# The VLESS+XHTTP+REALITY server itself runs on the VM (deploy_vm.py).
FROM debian:bookworm-slim
ARG DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
        dropbear-bin nginx python3 cmake build-essential git ca-certificates \
    && git clone --depth 1 https://github.com/ambrop72/badvpn.git /tmp/badvpn \
    && mkdir /tmp/badvpn/build && cd /tmp/badvpn/build \
    && cmake .. -DBUILD_NOTHING_BY_DEFAULT=1 -DBUILD_UDPGW=1 \
    && make -j"$(nproc)" install \
    && cd / && rm -rf /tmp/badvpn \
    && apt-get purge -y cmake build-essential git \
    && apt-get autoremove -y \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

RUN mkdir -p /etc/dropbear \
    && (grep -qx '/bin/false' /etc/shells || echo '/bin/false' >> /etc/shells) \
    && touch /etc/nginx/relay-upstream.conf /etc/nginx/relay-location.conf

COPY proxy/reality/banner.txt /etc/dropbear/banner.txt
COPY proxy/reality/nginx.conf /etc/nginx/nginx.conf
COPY proxy/reality/ws_bridge.py /opt/ws_bridge.py
COPY proxy/reality/cert_server.py /opt/cert_server.py
COPY proxy/reality/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 8080
ENTRYPOINT ["/entrypoint.sh"]
