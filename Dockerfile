# 基于轻量Debian镜像
FROM debian:bookworm-slim

# 维护者信息
LABEL maintainer="Han <vvhan.com>"

# 单行设置环境变量
ENV DEBIAN_FRONTEND=noninteractive GOST_VERSION=3.2.6 TZ=Asia/Shanghai

# 单行安装精简后的核心依赖
RUN apt update && apt install -y --no-install-recommends wget curl gnupg2 ca-certificates procps logrotate iproute2 dbus iptables supervisor iptables-persistent && apt clean && rm -rf /var/lib/apt/lists/*

# 导入WARP GPG密钥+添加源+安装WARP
RUN curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg | gpg --dearmor -o /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ bookworm main" | tee /etc/apt/sources.list.d/cloudflare-client.list && apt update && apt install -y cloudflare-warp && apt clean && rm -rf /var/lib/apt/lists/*

# 安装GOST（适配多架构 + 主备节点容错，无bash函数版）
RUN ARCH=$(dpkg --print-architecture) && curl -L "https://cdn.gh-proxy.org/https://github.com/go-gost/gost/releases/download/v${GOST_VERSION}/gost_${GOST_VERSION}_linux_${ARCH}.tar.gz" | tar xz -C /usr/local/bin && chmod +x /usr/local/bin/gost

# 创建日志目录
RUN mkdir -p /var/log/warp-gost

# 配置日志轮转（核心：限制单文件5MB，保留3个备份，自动压缩，7天清理）
RUN echo -e "/var/log/warp-gost/*.log {\n    daily\n    size 5M\n    rotate 3\n    compress\n    missingok\n    notifempty\n    copytruncate\n    maxage 7\n}" > /etc/logrotate.d/warp-gost

# COPY所有文件
COPY warp-gost.conf /etc/supervisor/conf.d/
COPY init-warp.sh /usr/local/bin/
COPY warp-monitor.sh /usr/local/bin/

# 赋予所有脚本执行权限
RUN chmod +x /usr/local/bin/init-warp.sh /usr/local/bin/warp-monitor.sh

# 暴露代理端口
EXPOSE 16666

# 启动命令：先初始化，再启动supervisord守护监控脚本
CMD ["/bin/bash", "-c", "/usr/local/bin/init-warp.sh && supervisord -c /etc/supervisor/supervisord.conf"]