#!/bin/bash

setup_dns() {
    echo "正在检测最佳 DNS 服务器..."

    local dns1="8.8.8.8"
    local dns2="1.1.1.1"
    local time1=0
    local time2=0

    time1=$(time_nslookup $dns1)
    time2=$(time_nslookup $dns2)

    if [ $time1 -lt $time2 ]; then
        echo "选择 DNS: $dns1 (响应时间: ${time1}ms)"
        echo "nameserver $dns1" > /etc/resolv.conf
    else
        echo "选择 DNS: $dns2 (响应时间: ${time2}ms)"
        echo "nameserver $dns2" > /etc/resolv.conf
    fi

    echo "nameserver 127.0.0.11" >> /etc/resolv.conf
}

time_nslookup() {
    local dns=$1
    local start end
    start=$(date +%s%3N)
    nslookup google.com $dns > /dev/null 2>&1
    end=$(date +%s%3N)
    echo $((end - start))
}

setup_dns
