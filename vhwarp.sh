#!/bin/bash

LOG_FILE="/var/log/warp-gost/vhwarp.log"
mkdir -p /var/log/warp-gost

log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

check_warp_svc() {
    if ! pgrep -x "warp-svc" > /dev/null; then
        echo "错误: warp-svc 未运行"
        return 1
    fi
    return 0
}

wait_for_connected() {
    local timeout=$1
    local count=0
    while [ $count -lt $timeout ]; do
        local status=$(warp-cli --accept-tos status 2>/dev/null)
        echo "$status" >> "$LOG_FILE"
        if echo "$status" | grep -q "Connected"; then
            return 0
        fi
        echo -n "."
        sleep 1
        count=$((count + 1))
    done
    return 1
}

clean_old_config() {
    log "清理旧配置..."
    warp-cli --accept-tos disconnect > /dev/null 2>&1 || true
    warp-cli --accept-tos registration delete > /dev/null 2>&1 || true
    sleep 1
}

configure_free_warp() {
    echo ""
    echo "配置 WARP 免费..."
    
    if ! check_warp_svc; then
        return 1
    fi

    clean_old_config
    log "开始配置 WARP 免费"

    warp-cli --accept-tos registration new > /dev/null 2>&1
    sleep 2

    warp-cli --accept-tos connect > /dev/null 2>&1
    echo -n "等待 WARP 连接（最长30秒）..."
    if wait_for_connected 30; then
        echo ""
        echo "✅ WARP 免费版配置成功！"
        log "WARP 免费版配置成功"
        show_status
        
        echo ""
        echo "正在启动 GOST 代理服务..."
        if /usr/local/bin/gost-setup.sh start; then
            echo "✅ GOST 代理服务已启动，监听端口: 16666"
        else
            echo "❌ GOST 代理服务启动失败"
        fi
    else
        echo ""
        echo "❌ WARP 连接失败"
        log "WARP 连接失败"
        return 1
    fi
}

configure_teams() {
    echo ""
    echo "配置 Teams (https://Team名字.cloudflareaccess.com/warp 获取)..."
    
    if ! check_warp_svc; then
        return 1
    fi

    read -p "请输入 Teams Token URL: " token_url
    
    if [ -z "$token_url" ]; then
        echo "❌ Token URL 不能为空"
        return 1
    fi

    clean_old_config
    log "开始配置 Teams"

    echo "正在注册 Teams Token..."
    warp-cli --accept-tos registration token "$token_url" > /dev/null 2>&1
    sleep 3

    echo "当前状态："
    warp-cli --accept-tos status
    echo ""

    echo "正在连接 WARP..."
    warp-cli --accept-tos connect > /dev/null 2>&1
    echo -n "等待 WARP 连接（最长60秒）..."
    if wait_for_connected 60; then
        echo ""
        echo "✅ Teams 配置成功！"
        log "Teams 配置成功"
        show_status
        
        echo ""
        echo "正在启动 GOST 代理服务..."
        if /usr/local/bin/gost-setup.sh start; then
            echo "✅ GOST 代理服务已启动，监听端口: 16666"
        else
            echo "❌ GOST 代理服务启动失败"
        fi
    else
        echo ""
        echo "❌ WARP 连接失败"
        echo ""
        echo "当前状态："
        warp-cli --accept-tos status
        echo ""
        echo "日志文件：$LOG_FILE"
        log "WARP 连接失败"
        return 1
    fi
}

configure_warp_plus() {
    echo ""
    echo "配置 WARP+ (License Key)..."
    
    if ! check_warp_svc; then
        return 1
    fi

    read -p "请输入 WARP+ License Key: " license_key
    
    if [ -z "$license_key" ]; then
        echo "❌ License Key 不能为空"
        return 1
    fi

    clean_old_config
    log "开始配置 WARP+: $license_key"

    warp-cli --accept-tos registration new
    sleep 2

    warp-cli --accept-tos registration license "$license_key"
    sleep 2

    warp-cli --accept-tos connect
    echo -n "等待 WARP 连接（最长30秒）..."
    if wait_for_connected 30; then
        echo ""
        echo "✅ WARP+ 配置成功！"
        log "WARP+ 配置成功"
        show_status
        
        echo ""
        echo "正在启动 GOST 代理服务..."
        if /usr/local/bin/gost-setup.sh start; then
            echo "✅ GOST 代理服务已启动，监听端口: 16666"
        else
            echo "❌ GOST 代理服务启动失败"
        fi
    else
        echo ""
        echo "❌ WARP 连接失败"
        log "WARP 连接失败"
        return 1
    fi
}

show_status() {
    echo "========================================"
    echo "当前状态："
    warp-cli --accept-tos status
    
    echo ""
    local reg_info=$(warp-cli --accept-tos registration show 2>/dev/null)
    
    if echo "$reg_info" | grep -q "Organization"; then
        echo "账户类型: Teams (Zero Trust)"
    elif echo "$reg_info" | grep -q "Premium"; then
        echo "账户类型: WARP+"
    elif echo "$reg_info" | grep -q "Device ID"; then
        echo "账户类型: WARP 免费版"
    else
        echo "账户类型: 未配置"
    fi
    
    echo "========================================"
    echo ""
}

reset_config() {
    echo "重置注册并清理配置..."
    
    if ! check_warp_svc; then
        return 1
    fi

    read -p "确认要重置吗？(y/n): " confirm
    if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
        echo "已取消"
        return 0
    fi

    log "开始重置配置"

    warp-cli --accept-tos disconnect > /dev/null 2>&1 || true
    sleep 2

    warp-cli --accept-tos registration delete > /dev/null 2>&1 || true
    sleep 2

    echo "正在停止 GOST 代理服务..."
    /usr/local/bin/gost-setup.sh stop > /dev/null 2>&1 || true

    echo "✅ 配置已重置"
}

show_menu() {
    clear
    echo ""
    echo "========================================"
    echo "       WARP 配置工具 (vhwarp)"
    echo "========================================"
    echo ""
    echo "1) 配置 WARP 免费"
    echo "2) 配置 Teams (Token URL)"
    echo "3) 配置 WARP+ (License Key)"
    echo "4) 查看当前状态"
    echo "5) 重置注册并清理配置"
    echo "0) 退出"
    echo ""
    echo "========================================"
}

main() {
    while true; do
        show_menu
        read -p "请选择 [0-5]: " choice
        
        case $choice in
            1)
                configure_free_warp
                read -p "按回车键继续..."
                ;;
            2)
                configure_teams
                read -p "按回车键继续..."
                ;;
            3)
                configure_warp_plus
                read -p "按回车键继续..."
                ;;
            4)
                show_status
                read -p "按回车键继续..."
                ;;
            5)
                reset_config
                read -p "按回车键继续..."
                ;;
            0)
                echo "退出"
                exit 0
                ;;
            *)
                echo "无效选择，请重新输入"
                sleep 1
                ;;
        esac
    done
}

main
