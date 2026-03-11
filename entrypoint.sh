#!/bin/bash

LOG_FILE="/var/log/warp-gost/entrypoint.log"
mkdir -p /var/log/warp-gost

log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

log "开始初始化..."

ln -sf /usr/local/bin/vhwarp.sh /usr/bin/vhwarp
ln -sf /usr/local/bin/setup-dns.sh /usr/bin/setup-dns
ln -sf /usr/local/bin/gost-setup.sh /usr/bin/gost-setup

if [ ! -e /dev/net/tun ]; then
    mkdir -p /dev/net
    mknod /dev/net/tun c 10 200
    chmod 600 /dev/net/tun
    log "创建 TUN 设备"
fi

if ! pgrep -x "dbus-daemon" > /dev/null; then
    service dbus start
    sleep 2
    log "启动 dbus"
fi

/usr/local/bin/setup-dns.sh

log "启动 warp-svc..."
warp-svc > /var/log/warp-gost/warp-svc.log 2>&1 &
WARP_PID=$!

sleep 3

if kill -0 $WARP_PID 2>/dev/null; then
    log "warp-svc 启动成功 (PID: $WARP_PID)"
else
    log "warp-svc 启动失败"
    exit 1
fi

until warp-cli --accept-tos status > /dev/null 2>&1; do
    log "等待 warp-cli 就绪..."
    sleep 1
done

log "warp-cli 已就绪"

echo "--------------------------------------------------------"
echo "🚀 WARP 代理容器已启动"
echo ""
echo "📝 下一步："
echo "1️⃣ 进入容器终端"
echo "2️⃣ 执行：vhwarp"
echo ""
echo "💡 示例："
echo "  docker exec -it warp-proxy bash"
echo "  vhwarp"
echo ""
echo "🔧 配置选项："
echo "1️⃣ WARP 免费版"
echo "2️⃣ Teams (Zero Trust)"
echo "3️⃣ WARP+ (License Key)"
echo "--------------------------------------------------------"

wait $WARP_PID
