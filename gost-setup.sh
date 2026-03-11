#!/bin/bash

LOG_FILE="/var/log/warp-gost/gost-setup.log"
mkdir -p /var/log/warp-gost

log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

configure_warp_iptables() {
    log "检测 WARP 网卡..."
    WARP_IF=$(ip link show 2>/dev/null | grep -E "CloudflareWARP|warp" | awk -F: '{print $2}' | tr -d ' ' | head -1)
    
    if [ -z "$WARP_IF" ]; then
        log "未找到 WARP 网卡"
        return 1
    fi
    
    WARP_IF_UP=$(ip link show "$WARP_IF" 2>/dev/null | grep -q "UP" && echo "1" || echo "0")
    if [ "${WARP_IF_UP}" != "1" ]; then
        log "WARP 网卡存在但未就绪（未UP）"
        return 1
    fi

    log "WARP 网卡: $WARP_IF（已就绪）"
    
    log "配置 iptables 规则..."
    iptables -t nat -F POSTROUTING 2>/dev/null || true
    iptables -t nat -A POSTROUTING -o "$WARP_IF" -j MASQUERADE
    iptables -F FORWARD 2>/dev/null || true
    iptables -A FORWARD -o "$WARP_IF" -j ACCEPT
    iptables -A FORWARD -i "$WARP_IF" -m state --state RELATED,ESTABLISHED -j ACCEPT
    log "iptables 规则配置完成"
    return 0
}

start_gost() {
    log "启动 GOST 代理服务（0.0.0.0:16666）..."
    
    if pgrep -x "gost" > /dev/null; then
        log "GOST 已在运行，先停止..."
        pkill -x "gost"
        sleep 1
    fi
    
    gost -L mixed://0.0.0.0:16666 > /var/log/warp-gost/gost.log 2>&1 &
    sleep 1
    
    if pgrep -x "gost" > /dev/null; then
        log "GOST 启动成功"
        return 0
    else
        log "GOST 启动失败"
        return 1
    fi
}

stop_gost() {
    log "停止 GOST 代理服务..."
    pkill -x "gost" || true
    sleep 1
    log "GOST 已停止"
}

case "$1" in
    start)
        if configure_warp_iptables; then
            start_gost
        else
            log "WARP 网卡配置失败，无法启动 GOST"
            exit 1
        fi
        ;;
    stop)
        stop_gost
        ;;
    restart)
        stop_gost
        sleep 1
        if configure_warp_iptables; then
            start_gost
        else
            log "WARP 网卡配置失败，无法启动 GOST"
            exit 1
        fi
        ;;
    status)
        if pgrep -x "gost" > /dev/null; then
            echo "GOST 运行中"
        else
            echo "GOST 未运行"
        fi
        ;;
    *)
        echo "用法: $0 {start|stop|restart|status}"
        exit 1
        ;;
esac
