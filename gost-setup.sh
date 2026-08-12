#!/bin/bash

LOG_FILE="/var/log/warp-gost/gost.log"
mkdir -p /var/log/warp-gost

log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

start_gost() {
    if pgrep -x gost > /dev/null 2>&1; then
        log "GOST 已在运行，跳过"
        return 0
    fi

    log "🚀 启动 GOST 代理 (监听 0.0.0.0:1111)..."

    gost -L "mixed://0.0.0.0:1111?udp=true&nodelay=true&backlog=4096&readTimeout=0&idleTimeout=600s&tcpKeepAlive=true&keepAlivePeriod=60&readBufferSize=66666&writeBufferSize=66666" \
        -F "socks5://127.0.0.1:40000" >> "$LOG_FILE" 2>&1 &

    local i=0
    while [ $i -lt 10 ]; do
        sleep 1
        if pgrep -x "gost" > /dev/null; then
            log "✅ GOST 启动成功，端口: 1111"
            return 0
        fi
        i=$((i + 1))
    done

    log "❌ GOST 启动失败"
}

stop_gost() {
    log "🛑 停止 GOST..."
    pkill -x gost 2>/dev/null || true
    sleep 1
    log "✅ GOST 已停止"
}

case "$1" in
    start)
        start_gost
        ;;
    stop)
        stop_gost
        ;;
    restart)
        stop_gost
        sleep 1
        start_gost
        ;;
    status)
        if pgrep -x "gost" > /dev/null; then
            echo "✅ GOST 运行中（端口 1111）"
        else
            echo "⭕ GOST 未运行"
        fi
        ;;
    *)
        echo "用法: $0 {start|stop|restart|status}"
        exit 1
        ;;
esac