# docker build -f proxies/ssh/Dockerfile -t IMAGE .
# nginx :8080 -> ws_bridge :2222 -> Dropbear :2200 (user/password)
# badvpn-udpgw :7300 carries UDP through the SSH tunnel.
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

# Tunnel-only accounts use /bin/false; Dropbear refuses shells missing from /etc/shells.
RUN mkdir -p /etc/dropbear \
    && (grep -qx '/bin/false' /etc/shells || echo '/bin/false' >> /etc/shells)

COPY proxies/ssh/banner.txt /etc/dropbear/banner.txt
COPY proxies/ssh/nginx.conf /etc/nginx/nginx.conf
COPY proxies/ssh/ws_bridge.py /opt/ws_bridge.py
COPY proxies/ssh/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 8080
ENTRYPOINT ["/entrypoint.sh"]
