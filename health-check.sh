#!/bin/bash

LOG_FILE="/var/log/warp-gost/health-check.log"
STATE_FILE="/var/log/warp-gost/health-state.txt"
FAILURE_SINCE_FILE="/var/log/warp-gost/health-failure-since.txt"
PUSHKEY_FILE="/var/lib/cloudflare-warp/pushdeer.key"

HEALTH_CHECK_INTERVAL="${HEALTH_CHECK_INTERVAL:-60}"
HEALTH_SOFT_FAILURES="${HEALTH_SOFT_FAILURES:-3}"
HEALTH_FALLBACK_AFTER="${HEALTH_FALLBACK_AFTER:-600}"
HEALTH_PROBE_TIMEOUT="${HEALTH_PROBE_TIMEOUT:-8}"
WARP_REGISTRATION_TIMEOUT="${WARP_REGISTRATION_TIMEOUT:-60}"
WARP_CONNECT_TIMEOUT="${WARP_CONNECT_TIMEOUT:-180}"

source /usr/local/bin/warp-common.sh
mkdir -p /var/log/warp-gost

log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}

pushdeer_send() {
    local key title body
    key=$(cat "$PUSHKEY_FILE" 2>/dev/null)
    [ -n "$key" ] || return 1
    title="$1"
    body="$2"
    curl -s --max-time 10 --get \
        --data-urlencode "pushkey=$key" \
        --data-urlencode "text=$title" \
        --data-urlencode "desp=$body" \
        "https://api2.pushdeer.com/message/push" > /dev/null 2>&1
}

get_fail_count() {
    local state
    state=$(cat "$STATE_FILE" 2>/dev/null)
    case "$state" in
        FAIL_*) echo "${state#FAIL_}" ;;
        *) echo 0 ;;
    esac
}

failure_elapsed() {
    local since now
    since=$(cat "$FAILURE_SINCE_FILE" 2>/dev/null)
    [ -n "$since" ] || { echo 0; return; }
    now=$(date +%s)
    echo $((now - since))
}

increment_failures() {
    local count
    count=$(get_fail_count)
    count=$((count + 1))
    if [ "$count" -eq 1 ]; then
        date +%s > "$FAILURE_SINCE_FILE"
    fi
    echo "FAIL_${count}" > "$STATE_FILE"
    echo "$count"
}

reset_failures() {
    local previous
    previous=$(cat "$STATE_FILE" 2>/dev/null)
    echo "MONITORING" > "$STATE_FILE"
    rm -f "$FAILURE_SINCE_FILE"
    if [ -n "$previous" ] && [ "$previous" != "MONITORING" ]; then
        log "✅ 健康恢复，原状态: $previous"
    fi
}

check_gost() {
    pgrep -x gost > /dev/null 2>&1 && ss -lnt 2>/dev/null | grep -q ':1111 '
}

restart_gost() {
    log "🔧 GOST 不可用，尝试重启"
    /usr/local/bin/gost-setup.sh restart >> "$LOG_FILE" 2>&1
    check_gost
}

probe_proxy_url() {
    local url="$1" result rc
    result=$(curl -sS --max-time "$HEALTH_PROBE_TIMEOUT" --socks5-hostname 127.0.0.1:1111 "$url" 2>&1)
    rc=$?
    if [ "$rc" -eq 0 ] && echo "$result" | grep -qE '^warp=(on|plus)$'; then
        return 0
    fi
    log "🔎 代理探针失败: url=$url curl_rc=$rc warp=$(echo "$result" | grep -E '^warp=' | head -1 | tr -d '\r')"
    return 1
}

check_proxy() {
    probe_proxy_url "https://www.cloudflare.com/cdn-cgi/trace" || \
        probe_proxy_url "https://one.one.one.one/cdn-cgi/trace"
}

check_direct_network() {
    curl -fsS --max-time "$HEALTH_PROBE_TIMEOUT" "https://www.cloudflare.com/cdn-cgi/trace" > /dev/null 2>&1 || \
        curl -fsS --max-time "$HEALTH_PROBE_TIMEOUT" "https://connectivitycheck.gstatic.com/generate_204" > /dev/null 2>&1
}

check_registration_api() {
    curl -sS --max-time "$HEALTH_PROBE_TIMEOUT" -o /dev/null "https://api.devices.cloudflare.com" 2>/dev/null
}

connect_current_registration() {
    local timeout="${1:-$WARP_CONNECT_TIMEOUT}"
    warp-cli --accept-tos tunnel protocol set MASQUE >> "$LOG_FILE" 2>&1 || true
    warp-cli --accept-tos proxy port 40000 >> "$LOG_FILE" 2>&1 || true
    warp-cli --accept-tos mode proxy >> "$LOG_FILE" 2>&1 || true
    warp-cli --accept-tos connect >> "$LOG_FILE" 2>&1 || true
    wait_for_connected "$timeout"
}

do_soft_reconnect() {
    log "🔄 软重连: disconnect → connect"
    pushdeer_send "WARP 软重连" "连续 ${HEALTH_SOFT_FAILURES} 次检测异常，正在保留当前注册并执行软重连。"
    if ! acquire_warp_lock 5; then
        log "⏸️ 用户配置正在进行，跳过软重连"
        return 1
    fi
    warp-cli --accept-tos disconnect >> "$LOG_FILE" 2>&1 || true
    sleep 3
    warp-cli --accept-tos connect >> "$LOG_FILE" 2>&1 || true
    wait_for_connected 30 || true
    if check_proxy; then
        release_warp_lock
        return 0
    fi
    log "⚠️ 软重连后仍不可用，断开 WARP 并继续恢复；GOST 不会绕过 WARP 直连"
    warp-cli --accept-tos disconnect >> "$LOG_FILE" 2>&1 || true
    release_warp_lock
    return 1
}

register_free() {
    if has_registration; then
        return 0
    fi
    log "🆕 创建 Free WARP 注册"
    if ! warp-cli --accept-tos registration new >> "$LOG_FILE" 2>&1; then
        log "⚠️ registration new 命令失败"
    fi
    if ! wait_for_registration "$WARP_REGISTRATION_TIMEOUT"; then
        log "⚠️ Free 注册在 ${WARP_REGISTRATION_TIMEOUT} 秒内未完成"
        return 1
    fi
    log "✅ Free WARP 注册完成"
    return 0
}

fallback_to_free() {
    local original_type
    original_type=$(get_account_type)
    log "🛟 准备可用性回退，当前账户: $original_type"

    if ! acquire_warp_lock 5; then
        log "⏸️ 用户配置正在进行，取消本轮回退"
        return 1
    fi

    warp-cli --accept-tos disconnect >> "$LOG_FILE" 2>&1 || true
    sleep 3
    if ! check_direct_network; then
        log "🌐 WARP 断开后基础网络仍不可用，保留原注册并取消回退"
        connect_current_registration 30 || true
        release_warp_lock
        return 2
    fi
    if ! check_registration_api; then
        log "🌐 WARP 注册 API 不可达，保留原注册；WARP Proxy 暂不可用"
        release_warp_lock
        return 4
    fi

    # Threshold may have elapsed while the original registration recovered.
    if connect_current_registration 45 && check_proxy; then
        log "✅ 最后一次原注册重连成功，取消 Free 回退"
        release_warp_lock
        return 0
    fi

    # The final reconnect may change routing state, so verify direct access again
    # before performing the irreversible registration deletion.
    warp-cli --accept-tos disconnect >> "$LOG_FILE" 2>&1 || true
    sleep 2
    if ! check_direct_network; then
        log "🌐 最后重连后基础网络异常，保留原注册并取消回退"
        release_warp_lock
        return 2
    fi

    log "💥 已确认基础网络正常且 WARP 持续不可用，回退到 Free"
    if has_registration; then
        warp-cli --accept-tos registration delete >> "$LOG_FILE" 2>&1 || true
        if ! wait_for_registration_deleted 30; then
            log "⚠️ 原注册删除未确认，停止本轮操作"
            release_warp_lock
            return 1
        fi
    fi

    if ! register_free; then
        echo "FREE_PENDING" > "$STATE_FILE"
        pushdeer_send "WARP Free 注册等待中" "原账户 ${original_type} 已回退。注册 API 暂时不可用，WARP Proxy 当前不可用，后台将退避重试。"
        release_warp_lock
        return 3
    fi

    if connect_current_registration "$WARP_CONNECT_TIMEOUT" && check_proxy; then
        log "✅ Free WARP 回退成功"
        pushdeer_send "WARP 已恢复为 Free" "原账户: ${original_type}\n当前账户: Free\n所有代理流量继续通过 WARP Proxy。"
        release_warp_lock
        return 0
    fi

    echo "FREE_PENDING" > "$STATE_FILE"
    log "⚠️ Free 已注册但暂未连通，后续继续重试"
    warp-cli --accept-tos disconnect >> "$LOG_FILE" 2>&1 || true
    release_warp_lock
    return 3
}

retry_free_until_healthy() {
    local delays=(60 120 300 600 900)
    local attempt=0 delay
    while true; do
        if ! check_gost; then
            restart_gost || log "⚠️ Free 恢复等待期间 GOST 重启失败"
        fi
        if check_proxy; then
            reset_failures
            return 0
        fi
        if [ "$attempt" -lt "${#delays[@]}" ]; then
            delay="${delays[$attempt]}"
            attempt=$((attempt + 1))
        else
            delay=900
        fi
        log "⏳ Free 恢复等待 ${delay} 秒；GOST 不会绕过 WARP 直连"
        sleep "$delay"
        if ! acquire_warp_lock 5; then
            log "⏸️ 用户配置正在进行，暂缓 Free 恢复"
            continue
        fi
        warp-cli --accept-tos disconnect >> "$LOG_FILE" 2>&1 || true
        sleep 2
        if ! check_direct_network; then
            log "🌐 基础网络不可用，暂缓 Free 注册/连接"
            release_warp_lock
            continue
        fi
        if ! has_registration && ! check_registration_api; then
            log "🌐 WARP 注册 API 不可达，暂缓 Free 注册"
            release_warp_lock
            continue
        fi
        if register_free; then
            connect_current_registration "$WARP_CONNECT_TIMEOUT" || true
        fi
        release_warp_lock
    done
}

monitor_loop() {
    local count elapsed fallback_rc
    log "💚 健康检测启动: interval=${HEALTH_CHECK_INTERVAL}s soft=${HEALTH_SOFT_FAILURES} fallback=${HEALTH_FALLBACK_AFTER}s"

    while true; do
        if ! check_gost; then
            restart_gost || log "⚠️ GOST 重启失败"
        fi

        if check_proxy; then
            reset_failures
            sleep "$HEALTH_CHECK_INTERVAL"
            continue
        fi

        if [ "$(cat "$STATE_FILE" 2>/dev/null)" = "FREE_PENDING" ]; then
            retry_free_until_healthy || true
            sleep "$HEALTH_CHECK_INTERVAL"
            continue
        fi

        # A missing registration after startup is recoverable without deleting anything.
        if ! has_registration && check_direct_network; then
            echo "FREE_PENDING" > "$STATE_FILE"
            retry_free_until_healthy || true
            continue
        fi

        count=$(increment_failures)
        elapsed=$(failure_elapsed)
        log "❌ 代理检测失败 #${count}，持续 ${elapsed} 秒，cli_connected=$(is_warp_connected && echo yes || echo no)"

        if [ "$count" -eq 1 ]; then
            pushdeer_send "WARP 检测异常" "首次检测异常，正在观察；不会立即删除账户注册。"
        fi

        if [ "$count" -eq "$HEALTH_SOFT_FAILURES" ]; then
            if do_soft_reconnect; then
                reset_failures
                sleep "$HEALTH_CHECK_INTERVAL"
                continue
            fi
        fi

        if [ "$elapsed" -ge "$HEALTH_FALLBACK_AFTER" ]; then
            fallback_to_free
            fallback_rc=$?
            case "$fallback_rc" in
                0) reset_failures ;;
                2) log "⏳ 基础网络异常，保留注册并重新开始观察"; reset_failures ;;
                3) retry_free_until_healthy || true ;;
                4) log "⏳ 注册 API 不可达，保留原注册；WARP Proxy 暂不可用" ;;
                *) log "⚠️ 本轮 Free 回退未执行，继续观察" ;;
            esac
        fi

        sleep "$HEALTH_CHECK_INTERVAL"
    done
}

log "🩺 健康检测守护进程启动中"
monitor_loop
