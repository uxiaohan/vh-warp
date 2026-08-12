FROM debian:bookworm-slim AS builder

ENV DEBIAN_FRONTEND=noninteractive
ENV GOST_VERSION=3.2.6

RUN apt update && apt install -y --no-install-recommends curl ca-certificates && \
    curl -fsSLo /tmp/warp.deb \
    "https://pkg.cloudflareclient.com/pool/bookworm/main/c/cloudflare-warp/cloudflare-warp_2026.6.880.0_$(dpkg --print-architecture).deb" && \
    dpkg-deb -x /tmp/warp.deb /tmp/warp && \
    mkdir -p /stage/rootfs/etc/dbus-1 && \
    cp /tmp/warp/bin/warp-cli /tmp/warp/bin/warp-svc /tmp/warp/bin/warp-diag /stage/ && \
    cp -a /tmp/warp/etc/dbus-1/. /stage/rootfs/etc/dbus-1/ 2>/dev/null || true && \
    rm -rf /tmp/warp.deb /tmp/warp

FROM debian:bookworm-slim

ARG GITHUB_PROXY=""
ENV DEBIAN_FRONTEND=noninteractive
ENV GOST_VERSION=3.2.6

RUN apt update && apt install -y --no-install-recommends \
    curl ca-certificates procps iproute2 nftables dbus tzdata \
    libcap2-bin libnss3-tools libpcap0.8 \
    libtss2-esys-3.0.2-0 libtss2-tctildr0 \
    && apt clean && rm -rf /var/lib/apt/lists/*

RUN ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime && \
    echo "Asia/Shanghai" > /etc/timezone

COPY --from=builder /stage/warp-cli /stage/warp-svc /stage/warp-diag /usr/bin/
COPY --from=builder /stage/rootfs/ /

RUN ldconfig && \
    setcap cap_setuid,cap_setgid,cap_dac_read_search,cap_net_bind_service,cap_sys_ptrace+ei /usr/bin/warp-svc && \
    ARCH=$(dpkg --print-architecture) && \
    curl -fsSL -o /tmp/gost.tar.gz \
    "${GITHUB_PROXY}https://github.com/go-gost/gost/releases/download/v${GOST_VERSION}/gost_${GOST_VERSION}_linux_${ARCH}.tar.gz" && \
    tar xzf /tmp/gost.tar.gz -C /usr/local/bin gost && \
    chmod +x /usr/local/bin/gost && rm /tmp/gost.tar.gz && \
    mkdir -p /var/log/warp-gost

COPY entrypoint.sh vhwarp.sh gost-setup.sh log-monitor.sh health-check.sh warp-common.sh /usr/local/bin/

RUN chmod +x /usr/local/bin/entrypoint.sh \
    /usr/local/bin/vhwarp.sh \
    /usr/local/bin/gost-setup.sh \
    /usr/local/bin/log-monitor.sh \
    /usr/local/bin/health-check.sh \
    /usr/local/bin/warp-common.sh && \
    which warp-cli && which warp-svc && which warp-diag && which gost && \
    echo "=== 构建验证通过 ===" && \
    warp-cli --version

EXPOSE 1111

ENV TZ=Asia/Shanghai

HEALTHCHECK --interval=30s --timeout=12s --start-period=60s --retries=3 \
    CMD curl -fsS --max-time 8 --socks5-hostname 127.0.0.1:1111 https://www.cloudflare.com/cdn-cgi/trace | grep -qE '^warp=(on|plus)$'

CMD ["/usr/local/bin/entrypoint.sh"]
