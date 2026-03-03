#!/bin/bash
set -euo pipefail
INIT_LOG="/var/log/warp-gost/init.log"
touch ${INIT_LOG}

log() {
    echo "$1"
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1" >> ${INIT_LOG}
}

# 初始化前清理旧进程（避免冲突）
clean_old_process() {
    log "✅ 初始化环境"
    pkill -x "gost" || true
    pkill -x "warp-svc" || true
    sleep 2
}

# 配置WARP网卡+iptables（仅当网卡就绪时执行）
configure_warp_iptables() {
    log "🔍 检测WARP网卡"
    # 双重检测：网卡存在 + 网卡UP状态（官方要求）
    WARP_IF=$(ip link show 2>/dev/null | grep -E "CloudflareWARP|warp" | awk -F: '{print $2}' | tr -d ' ' | head -1)
    if [ -z "$WARP_IF" ]; then
        log "❌ 未找到 WARP 网卡"
        return 1
    fi
    # 检测网卡是否UP（官方关键指标）
    WARP_IF_UP=$(ip link show "$WARP_IF" 2>/dev/null | grep -q "UP" && echo "1" || echo "0")
    if [ "${WARP_IF_UP}" != "1" ]; then
        log "❌ WARP网卡存在但未就绪（未UP）"
        return 1
    fi

    log "✅ WARP 网卡: $WARP_IF（已就绪）"
    # 配置iptables规则（此时绑定有效）
    log "🔧 配置iptables规则..."
    iptables -t nat -F POSTROUTING 2>/dev/null || true
    iptables -t nat -A POSTROUTING -o "$WARP_IF" -j MASQUERADE
    iptables -F FORWARD 2>/dev/null || true
    iptables -A FORWARD -o "$WARP_IF" -j ACCEPT
    iptables -A FORWARD -i "$WARP_IF" -m state --state RELATED,ESTABLISHED -j ACCEPT
    log "✅ iptables规则配置完成"
    return 0
}

# 主流程
log "===== WARP + GOST 启动（$(date)）====="
clean_old_process

# 初始化TUN设备
if [ ! -e /dev/net/tun ]; then
    mkdir -p /dev/net
    mknod /dev/net/tun c 10 200
    chmod 600 /dev/net/tun
fi

# 启动dbus（WARP依赖）
if ! pgrep -x "dbus-daemon" > /dev/null; then
    service dbus start
    sleep 2
fi

# 步骤1：启动warp-svc（日志分流到指定文件，不显示在docker logs）
log "⌛️ 启动 warp-svc..."
# 创建日志目录（确保存在）
mkdir -p /var/log/warp-gost
if ! pgrep -x "warp-svc" > /dev/null; then
    # 核心：warp-svc日志全部写入指定文件，不进入容器stdout
    warp-svc > /var/log/warp-gost/warp-svc.log 2>&1 &
    sleep 3  # 官方推荐启动后等待3秒
fi
if pgrep -x "warp-svc" > /dev/null; then
    log "✅ warp-svc 已启动"
else
    log "❌ warp-svc 启动失败"
    exit 1
fi

# 步骤2：连接WARP（阻塞式，直到Connected）
log "⌛️ 连接 WARP..."
# 先等待warp-cli可用
until warp-cli --accept-tos status > /dev/null 2>&1; do
    sleep 1
done
# 注册新设备（首次启动）
if ! warp-cli --accept-tos registration show 2>&1 | grep -q "Device ID"; then
    log "🔄 首次启动，注册新设备..."
    warp-cli --accept-tos registration new
    sleep 2
fi
# 连接并等待Connected状态（官方要求的就绪状态）
if ! warp-cli --accept-tos status | grep -q "Connected"; then
    warp-cli --accept-tos connect
    until warp-cli --accept-tos status | grep -q "Connected"; do
        sleep 1
    done
fi
# 最终验证连接状态
if warp-cli --accept-tos status | grep -q "Connected"; then
    log "✅ WARP 已连接"
else
    log "❌ WARP 连接失败"
    exit 1
fi

# 步骤3：配置WARP网卡+iptables（此时网卡已UP）
if ! configure_warp_iptables; then
    log "❌ WARP网卡配置失败，退出初始化"
    exit 1
fi

# 步骤4：启动GOST（仅当网卡+iptables就绪后）
log "启动 GOST（0.0.0.0:16666）..."
if ! pgrep -x "gost" > /dev/null; then
    gost -L mixed://0.0.0.0:16666 > /var/log/warp-gost/gost.log 2>&1 &
    sleep 1
fi
if pgrep -x "gost" > /dev/null; then
    log "✅ GOST 已启动"
else
    log "❌ GOST 启动失败"
    exit 1
fi

# 打印完成信息
log "========================================"
log "✅ 服务启动完成！"
CONTAINER_IP=$(ip addr show eth0 | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1)
log "⚠️ 如果Docker运行在软路由内，请添加当前容器IP不走代理: ${CONTAINER_IP}"
log "========================================"
log "🍓 warp-svc    日志:   /var/log/warp-gost/warp-svc.log"
log "🍊 gost        日志:   /var/log/warp-gost/gost.log"
log "🥝 初始化      日志:   /var/log/warp-gost/init.log"
log "🥑 监控        日志:   /var/log/warp-gost/monitor.log"
log "========================================"
log "✅ 查看warp-svc日志命令: docker exec -it 容器名 tail -f /var/log/warp-gost/warp-svc.log"
log "✅ 请在容器内使用 warp-cli 命令切换自己的账号，支持所有类型warp账号（包括Team）."