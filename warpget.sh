#!/bin/bash
# /root/warp-monitor.sh
# WARP IPv4 自动恢复脚本

# ===== 配置 =====
TARGET="1.1.1.1"      # Ping 目标
COUNT=5               # Ping 次数
SLEEP_INTERVAL=10     # 重试间隔
MAX_RETRY=3           # 最大重试次数
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

# ===== 网络检测函数（一次 ping 获取全部信息）=====
check_ipv4_status() {
    local result loss
    result=$(ping -4 -q -c ${COUNT} -W 3 ${TARGET} 2>/dev/null)
    loss=$(echo "$result" | grep -oP '\d+(?=% packet loss)')
    [ -z "$loss" ] && loss=100
    echo "$loss"
    [ "$loss" -lt 100 ]  # 返回 true 表示连通
}

# ===== 重置 WARP =====
reset_warp_v4() {
    echo -e "${YELLOW}正在重新获取WARP v4出口...${NC}"
    wg-quick down warp &>/dev/null
    sleep 1
    wg-quick up warp &>/dev/null
    sleep 5
    echo -e "${BLUE}WARP v4出口重置完成${NC}"
}

# ===== 主逻辑 =====
echo -e "${GREEN}===============================================${NC}"
echo -e "${GREEN}     WARP IPv4出口自动恢复脚本启动${NC}"
echo -e "${GREEN}===============================================${NC}"

logger "开始执行WARP IPv4连通性检测..."
retry_count=0

if check_ipv4_status; then
    loss=$(check_ipv4_status)
    log="[丢包率 ${loss}%] IPv4网络连通正常，无需处理"
    echo -e "${GREEN}${log}${NC}"
    logger "${log}"
    exit 0
fi

while [ $retry_count -lt $MAX_RETRY ]; do
    retry_count=$((retry_count + 1))
    loss=$(check_ipv4_status)
    log="[第${retry_count}次重试] [丢包率 ${loss}%] IPv4网络中断，正在重新获取WARP v4出口..."
    echo -e "${RED}${log}${NC}"
    logger "${log}"

    reset_warp_v4
    echo -e "${YELLOW}等待 ${SLEEP_INTERVAL} 秒让网络稳定...${NC}"
    sleep ${SLEEP_INTERVAL}

    if check_ipv4_status; then
        loss=$(check_ipv4_status)
        log="[丢包率 ${loss}%] IPv4网络已恢复正常！"
        echo -e "${GREEN}${log}${NC}"
        logger "${log}"
        exit 0
    fi
done

log="已达到最大重试次数(${MAX_RETRY})，IPv4网络仍未恢复，请手动检查WARP配置"
echo -e "${RED}${log}${NC}"
logger "${log}"
exit 1
