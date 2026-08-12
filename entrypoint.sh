#!/bin/bash

LOG_DIR="/var/log/warp-gost"
LOG_FILE="$LOG_DIR/entrypoint.log"
WARP_CLI_TIMEOUT="${WARP_CLI_TIMEOUT:-60}"
WARP_REGISTRATION_TIMEOUT="${WARP_REGISTRATION_TIMEOUT:-60}"
WARP_CONNECT_TIMEOUT="${WARP_CONNECT_TIMEOUT:-180}"

source /usr/local/bin/warp-common.sh

mkdir -p "$LOG_DIR"

log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

log "🚀 vh-warp 容器启动中..."

ln -sf /usr/local/bin/vhwarp.sh /usr/bin/vhwarp 2>/dev/null
ln -sf /usr/local/bin/gost-setup.sh /usr/bin/gost-setup 2>/dev/null
ln -sf /usr/local/bin/log-monitor.sh /usr/bin/log-monitor 2>/dev/null
ln -sf /usr/local/bin/health-check.sh /usr/bin/health-check 2>/dev/null

if ! pgrep -x "dbus-daemon" > /dev/null 2>&1; then
    dbus-daemon --system --fork 2>/dev/null || \
    service dbus start 2>/dev/null || \
    mkdir -p /var/run/dbus && dbus-daemon --system --fork 2>/dev/null || \
    true
    sleep 2
    log "✅ dbus 已启动"
fi

log "⏳ 正在启动 warp-svc..."
mkdir -p /run/cloudflare-warp
warp-svc >> "$LOG_DIR/warp-svc.log" 2>&1 &
WARP_PID=$!

attempt=1
MAX_ATTEMPTS=5
while true; do
    sleep 10
    if kill -0 $WARP_PID 2>/dev/null; then
        log "✅ warp-svc 启动成功 (PID: $WARP_PID)"
        break
    fi
    if [ $attempt -ge $MAX_ATTEMPTS ]; then
        log "❌ warp-svc 启动失败，已重试 ${MAX_ATTEMPTS} 次，容器退出"
        exit 1
    fi
    log "⏳ warp-svc 未就绪，第 ${attempt}/${MAX_ATTEMPTS} 次尝试，10 秒后重试..."
    attempt=$((attempt + 1))
    warp-svc >> "$LOG_DIR/warp-svc.log" 2>&1 &
    WARP_PID=$!
done

log "⏳ 等待 warp-cli 就绪（最长 ${WARP_CLI_TIMEOUT} 秒）..."
warp_cli_available=false
if wait_for_warp_cli "$WARP_CLI_TIMEOUT"; then
    warp_cli_available=true
    log "✅ warp-cli 已就绪"
else
    log "⚠️ warp-cli 未就绪，跳过自动配置，WARP Proxy 暂不可用"
fi

/usr/local/bin/gost-setup.sh start

connect_warp() {
    local attempt delay
    for attempt in 1 2 3; do
        log "⚡ WARP 连接尝试 ${attempt}/3..."
        if ! warp-cli --accept-tos connect >> "$LOG_FILE" 2>&1; then
            log "⚠️ connect 命令失败（尝试 ${attempt}/3）"
        fi
        if wait_for_connected "$WARP_CONNECT_TIMEOUT"; then
            log "🌐 WARP 连接成功"
            return 0
        fi
        warp-cli --accept-tos disconnect >> "$LOG_FILE" 2>&1 || true
        case "$attempt" in
            1) delay=5 ;;
            2) delay=15 ;;
            *) delay=0 ;;
        esac
        [ "$delay" -gt 0 ] && sleep "$delay"
    done
    return 1
}

if [ "$warp_cli_available" = true ]; then
    log "🔍 检测 WARP 注册状态..."
    if is_warp_connected; then
        log "🌐 WARP 已连接"
    elif acquire_warp_lock 30; then
        if ! has_registration; then
            log "🆕 未注册，自动注册免费版..."
            if ! warp-cli --accept-tos registration new >> "$LOG_FILE" 2>&1; then
                log "⚠️ registration new 命令失败"
            fi
            if wait_for_registration "$WARP_REGISTRATION_TIMEOUT"; then
                log "✅ 免费版注册完成"
            else
                log "⚠️ 注册超时，WARP Proxy 暂不可用，健康检测稍后重试"
            fi
        else
            log "⚡ 检测到现有 $(get_account_type) 注册"
        fi

        if has_registration; then
            if ! warp-cli --accept-tos tunnel protocol set MASQUE >> "$LOG_FILE" 2>&1; then
                log "⚠️ MASQUE 隧道协议设置失败，请检查 Teams 后台设备配置"
            fi
            if ! warp-cli --accept-tos proxy port 40000 >> "$LOG_FILE" 2>&1; then
                log "⚠️ WARP Proxy 端口设置失败"
            fi
            if ! warp-cli --accept-tos mode proxy >> "$LOG_FILE" 2>&1; then
                log "⚠️ WARP Proxy 模式设置失败"
            fi
            if ! connect_warp; then
                log "⚠️ WARP 暂时无法连接，WARP Proxy 暂不可用，健康检测继续恢复"
            fi
        fi
        release_warp_lock
    else
        log "⚠️ 无法取得 WARP 操作锁，跳过自动配置"
    fi
fi

log "📋 正在启动日志监控..."
/usr/local/bin/log-monitor.sh > /dev/null 2>&1 &

log "🩺 正在启动健康检测..."
/usr/local/bin/health-check.sh > /dev/null 2>&1 &

echo ""
echo "========================================"
echo "  🥝 vh-warp Cloudflare WARP 隐私保护 + 网络加速"
echo ""
echo "  📝 下一步："
echo "  1) docker exec -it vh-warp bash"
echo "  2) vhwarp"
echo ""
echo "  🔧 配置选项："
echo "  1) WARP 免费版 (Proxy + MASQUE)"
echo "  2) Teams / Zero Trust"
echo "  3) WARP+ (License Key)"
echo ""
echo "  🌐 SOCKS5/HTTP: 主机IP:1111"
echo "  ⚠️  首次配置可能需等待 3 分钟，请耐心等待"
echo "========================================"
echo ""

log "✅ 日志监控已启动"
log "✅ 健康检测已启动"

wait $WARP_PID
