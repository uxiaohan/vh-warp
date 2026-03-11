FROM debian:bookworm-slim

LABEL maintainer="Han <www.vvhan.com>"

ENV DEBIAN_FRONTEND=noninteractive TZ=Asia/Shanghai PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

RUN apt update && apt install -y --no-install-recommends \
    wget \
    curl \
    gnupg2 \
    ca-certificates \
    procps \
    iproute2 \
    dbus \
    iptables \
    net-tools \
    dnsutils \
    bash \
    && apt clean \
    && rm -rf /var/lib/apt/lists/*

RUN curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg | gpg --dearmor -o /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg && \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ bookworm main" | tee /etc/apt/sources.list.d/cloudflare-client.list && \
    apt update && \
    apt install -y cloudflare-warp && \
    apt clean && \
    rm -rf /var/lib/apt/lists/*

ENV GOST_VERSION=3.2.6
RUN ARCH=$(dpkg --print-architecture) && \
    curl -L "https://github.com/go-gost/gost/releases/download/v${GOST_VERSION}/gost_${GOST_VERSION}_linux_${ARCH}.tar.gz" | tar xz -C /usr/local/bin && \
    chmod +x /usr/local/bin/gost

RUN mkdir -p /var/log/warp-gost

COPY entrypoint.sh /usr/local/bin/
COPY vhwarp.sh /usr/local/bin/
COPY setup-dns.sh /usr/local/bin/
COPY gost-setup.sh /usr/local/bin/

RUN chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/vhwarp.sh /usr/local/bin/setup-dns.sh /usr/local/bin/gost-setup.sh

EXPOSE 16666

CMD ["/usr/local/bin/entrypoint.sh"]
