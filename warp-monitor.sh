#!/bin/bash
set -euo pipefail

# 日志文件
MONITOR_LOG="/var/log/warp-gost/monitor.log"
touch ${MONITOR_LOG}

# 日志函数
log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1"
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1" >> ${MONITOR_LOG}
}

# 配置WARP网卡+iptables（仅当网卡就绪时执行）
configure_warp_iptables() {
    log "🔍 检测WARP网卡..."
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

# 场景1：全流程重启（warp-svc崩溃/网卡消失）
full_restart() {
    log "⚠️ warp-svc进程崩溃，执行全流程重启..."
    # 清理旧进程
    pkill -x "gost" || true
    pkill -x "warp-svc" || true
    sleep 2
    # 确保dbus正常
    if ! pgrep -x "dbus-daemon" > /dev/null; then
        service dbus start
        sleep 2
    fi
    # 重启warp-svc（日志分流到指定文件）
    mkdir -p /var/log/warp-gost
    warp-svc > /var/log/warp-gost/warp-svc.log 2>&1 &
    sleep 3  # 官方推荐等待时间
    # 重连WARP（先确保Connected）
    log "🔄 重连WARP..."
    until warp-cli --accept-tos status 2>/dev/null | grep -q "Connected"; do
        warp-cli --accept-tos connect
        sleep 2
    done
    # 配置网卡+iptables（此时网卡已就绪）
    if ! configure_warp_iptables; then
        log "❌ WARP网卡配置失败，全流程重启失败"
        exit 1
    fi
    # 重启GOST（日志分流）
    log "🔄 重启GOST..."
    gost -L mixed://0.0.0.0:16666 > /var/log/warp-gost/gost.log 2>&1 &
    sleep 1
    log "✅ 全流程重启完成"
}

# 场景2：仅重连WARP+重启GOST（warp-svc正常，仅连接断开）
reconnect_warp_and_restart_gost() {
    log "⚠️ WARP连接断开，执行重连+重启GOST..."
    # 重连WARP（最多重试5次）
    retry_count=0
    max_retry=5
    until warp-cli --accept-tos status 2>/dev/null | grep -q "Connected" || [ $retry_count -ge $max_retry ]; do
        log "🔄 尝试重连WARP（第${retry_count}次）..."
        warp-cli --accept-tos connect
        retry_count=$((retry_count + 1))
        sleep 2
    done

    # 重连成功：重启GOST（无需重配iptables，网卡仍UP）
    if warp-cli --accept-tos status 2>/dev/null | grep -q "Connected"; then
        log "✅ WARP重连成功"
        log "🔄 重启GOST..."
        pkill -x "gost" || true
        sleep 1
        gost -L mixed://0.0.0.0:16666 > /var/log/warp-gost/gost.log 2>&1 &
        sleep 1
        if pgrep -x "gost" > /dev/null; then
            log "✅ GOST重启成功"
        else
            log "❌ GOST重启失败，触发全流程重启..."
            full_restart
        fi
    else
        log "❌ WARP重连失败（重试${max_retry}次），触发全流程重启..."
        full_restart
    fi
}

# 主监控循环（每5秒检测一次）
log "===== WARP智能监控脚本启动 ====="
while true; do
    # 检测warp-svc进程状态
    WARP_SVC_RUNNING=$(pgrep -x "warp-svc" > /dev/null && echo "1" || echo "0")
    # 检测WARP连接状态（仅进程正常时检测）
    WARP_CONNECTED="0"
    if [ "${WARP_SVC_RUNNING}" = "1" ]; then
        WARP_CONNECTED=$(warp-cli --accept-tos status 2>/dev/null | grep -q "Connected" && echo "1" || echo "0")
    fi

    # 分场景处理
    if [ "${WARP_SVC_RUNNING}" != "1" ]; then
        full_restart
    elif [ "${WARP_CONNECTED}" != "1" ]; then
        reconnect_warp_and_restart_gost
    fi

    sleep 5
done