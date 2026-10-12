# docker build -f proxies/ssh/Dockerfile -t IMAGE .
# Standalone SSH-over-WS gateway - not part of the VLESS/VMess/Trojan/SS
# multi-protocol image. Same idea as the working reference this was built
# from, on debian-slim instead of Ubuntu (smaller, same glibc badvpn needs
# to build cleanly).
FROM debian:bookworm-slim
ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
        openssh-server nginx python3 cmake build-essential git ca-certificates \
    && git clone --depth 1 https://github.com/ambrop72/badvpn.git /tmp/badvpn \
    && cd /tmp/badvpn && mkdir build && cd build \
    && cmake .. -DBUILD_NOTHING_BY_DEFAULT=1 -DBUILD_UDPGW=1 \
    && make install \
    && cd / && rm -rf /tmp/badvpn \
    && apt-get purge -y cmake build-essential git \
    && apt-get autoremove -y \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

RUN mkdir -p /var/run/sshd \
    && sed -i 's/#PermitRootLogin prohibit-password/PermitRootLogin no/' /etc/ssh/sshd_config \
    && sed -i 's/PasswordAuthentication no/PasswordAuthentication yes/' /etc/ssh/sshd_config \
    && { \
        echo "UseDNS no"; \
        echo "TCPKeepAlive yes"; \
        echo "ClientAliveInterval 15"; \
        echo "ClientAliveCountMax 3"; \
        echo "MaxSessions 50"; \
        echo "MaxStartups 50:30:100"; \
        echo "Compression no"; \
       } >> /etc/ssh/sshd_config

COPY proxies/ssh/banner.html /etc/ssh/banner.html
RUN echo "Banner /etc/ssh/banner.html" >> /etc/ssh/sshd_config

COPY proxies/ssh/nginx.conf /etc/nginx/nginx.conf
COPY proxies/ssh/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 8080
ENTRYPOINT ["/entrypoint.sh"]
