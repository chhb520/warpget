#!/bin/bash
# /root/warp-monitor.sh
# WARP IPv4 & IPv6 自动恢复脚本

# ===== 配置 =====
TARGET_V4="1.1.1.1"                     # IPv4 Ping 目标
TARGET_V6="2606:4700:4700::1111"        # IPv6 Ping 目标
COUNT=5                                 # Ping 次数
SLEEP_INTERVAL=10                       # 重试间隔
MAX_RETRY=3                             # 最大重试次数
LOCK_FILE="/tmp/$(basename $0).lock"

# ===== 颜色 =====
GREEN="\033[0;32m"
RED="\033[0;31m"
YELLOW="\033[1;33m"
BLUE="\033[0;34m"
NC="\033[0m"

# ===== 检查依赖 =====
command -v ping &>/dev/null || { echo "缺少 ping 命令"; exit 1; }
command -v logger &>/dev/null || logger() { :; } # 兼容无 logger

# ===== 锁文件防并发 =====
if [ -e "$LOCK_FILE" ] && kill -0 "$(cat "$LOCK_FILE")" 2>/dev/null; then
    log_message="脚本已在运行中 (PID: $(cat "$LOCK_FILE"))，退出。"
    echo -e "${YELLOW}${log_message}${NC}"
    logger "${log_message}"
    exit 1
fi
echo $$ > "$LOCK_FILE"

trap 'rm -f "$LOCK_FILE"; echo -e "${BLUE}清理锁文件并退出${NC}"' EXIT

# ===== 检查 root 权限 =====
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}错误: 此脚本需要 root 权限${NC}"
    exit 1
fi

# ===== 检测函数 =====
check_status() {
    local ipver=$1 target=$2
    local result loss

    if [ "$ipver" = "4" ]; then
        result=$(ping -4 -q -c ${COUNT} -W 3 ${target} 2>/dev/null)
    else
        # 兼容 ping6
        if command -v ping6 &>/dev/null; then
            result=$(ping6 -q -c ${COUNT} -W 3 ${target} 2>/dev/null)
        else
            result=$(ping -6 -q -c ${COUNT} -W 3 ${target} 2>/dev/null)
        fi
    fi

    loss=$(echo "$result" | grep -oP '\d+(?=% packet loss)')
    [ -z "$loss" ] && loss=100
    echo "$loss"
    [ "$loss" -lt 100 ] # true 表示连通
}

# ===== 重置 WARP =====
reset_warp() {
    echo -e "${YELLOW}正在重新获取 WARP 出口...${NC}"
    wg-quick down warp &>/dev/null
    sleep 1
    wg-quick up warp &>/dev/null
    sleep 5
    echo -e "${BLUE}WARP 出口重置完成${NC}"
}

# ===== 主逻辑 =====
echo -e "${GREEN}===============================================${NC}"
echo -e "${GREEN}     WARP IPv4 & IPv6 出口自动恢复脚本启动${NC}"
echo -e "${GREEN}===============================================${NC}"

logger "开始执行 WARP IPv4 & IPv6 连通性检测..."
retry_count=0

while [ $retry_count -lt $MAX_RETRY ]; do
    retry_count=$((retry_count + 1))

    loss4=$(check_status 4 $TARGET_V4); status4=$?
    loss6=$(check_status 6 $TARGET_V6); status6=$?

    if [ $status4 -eq 0 ] && [ $status6 -eq 0 ]; then
        log="[IPv4 丢包率 ${loss4}%] [IPv6 丢包率 ${loss6}%] 网络正常，无需处理"
        echo -e "${GREEN}${log}${NC}"
        logger "${log}"
        exit 0
    fi

    if [ $status4 -ne 0 ] && [ $status6 -ne 0 ]; then
        log="[IPv4 丢包率 ${loss4}%] [IPv6 丢包率 ${loss6}%] 网络均中断，执行 WARP 重置"
        echo -e "${RED}${log}${NC}"
        logger "${log}"
        reset_warp
    elif [ $status4 -ne 0 ]; then
        log="[IPv4 丢包率 ${loss4}%] IPv4 网络中断，执行 WARP 重置"
        echo -e "${RED}${log}${NC}"
        logger "${log}"
        reset_warp
    elif [ $status6 -ne 0 ]; then
        log="[IPv6 丢包率 ${loss6}%] IPv6 网络中断，执行 WARP 重置"
        echo -e "${RED}${log}${NC}"
        logger "${log}"
        reset_warp
    fi

    echo -e "${YELLOW}等待 ${SLEEP_INTERVAL} 秒让网络稳定...${NC}"
    sleep ${SLEEP_INTERVAL}
done

log="已达到最大重试次数(${MAX_RETRY})，网络仍未恢复，请手动检查 WARP 配置"
echo -e "${RED}${log}${NC}"
logger "${log}"
exit 1
