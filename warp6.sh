#!/usr/bin/env bash

# =============================================
# 优化版 WARP IPv6 出口自动恢复脚本
# =============================================

# --- 全局配置 ---
readonly TARGET="2606:4700:4700::1111" # Ping 测试目标 (IPv6)
readonly COUNT=5                       # Ping 次数
readonly PING_TIMEOUT=3                # Ping 超时(秒)
readonly SLEEP_INTERVAL=10             # 重试间隔(秒)
readonly MAX_RETRY=3                   # 最大重试次数
readonly LOCK_FILE="/tmp/warp_ipv6_monitor.lock" # 锁文件路径
readonly LOG_FILE="/var/log/warp_ipv6_monitor.log" # 日志文件路径
readonly WARP_CONFIG="/etc/wireguard/warp.conf" # WARP 配置文件路径

# 备用 WARP Endpoint (IPv4), WARP v6本身没有独立地址
# 重置时会通过切换IPv4 Endpoint来重新建立v6隧道
declare -a FALLBACK_ENDPOINTS=(
    "engage.cloudflareclient.com:4500"
    "use.cloudflareclient.com:2408" # 备用地址1
    "use.cloudflareclient.com:854"  # 备用地址2
)

# --- 颜色配置 ---
declare -A COLORS=(
    [RED]="\033[0;31m"
    [GREEN]="\033[0;32m"
    [YELLOW]="\033[1;33m"
    [BLUE]="\033[0;34m"
    [CYAN]="\033[0;36m"
    [NC]="\033[0m"
)

# --- 初始化 ---
init() {
    check_root
    setup_logging
    check_lock
    create_lock
    set_traps
    find_commands
}

# --- 检查root权限 ---
check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${COLORS[RED]}错误: 此脚本需要root权限来访问 warp-cli。请使用 sudo 执行。${COLORS[NC]}" >&2
        exit 1
    fi
}

# --- 查找关键命令路径 ---
find_commands() {
    readonly PING_CMD=$(which ping)
    readonly PING6_CMD=$(which ping6)
    readonly WG_QUICK_CMD=$(which wg-quick)
    readonly WARP_CMD=$(which warp)

    if [[ -z "$PING6_CMD" || -z "$WG_QUICK_CMD" || -z "$WARP_CMD" ]]; then
        echo -e "${COLORS[RED]}错误: 找不到 ping6, wg-quick 或 warp 命令，请确保已安装。${COLORS[NC]}" >&2
        exit 1
    fi
}

# --- 日志设置 ---
setup_logging() {
    mkdir -p "$(dirname "$LOG_FILE")"
    touch "$LOG_FILE"
}

# --- 检查锁文件 ---
check_lock() {
    if [[ -e "$LOCK_FILE" ]]; then
        local pid=$(cat "$LOCK_FILE")
        if ps -p "$pid" > /dev/null; then
            echo -e "${COLORS[YELLOW]}警告: 脚本已在运行中${COLORS[NC]}" >&2
            exit 1
        else
            rm -f "$LOCK_FILE"
        fi
    fi
}

# --- 创建锁文件 ---
create_lock() {
    echo $$ > "$LOCK_FILE"
}

# --- 设置陷阱 ---
set_traps() {
    trap 'cleanup' EXIT INT TERM
}

# --- 清理函数 ---
cleanup() {
    rm -f "$LOCK_FILE"
    echo -e "\n${COLORS[CYAN]}脚本执行完成${COLORS[NC]}"
}

# --- 日志记录函数 ---
log_message() {
    local level=$1
    local message=$2
    local timestamp=$(date "+%Y-%m-%d %H:%M:%S")

    logger -t "WARP_IPv6_Monitor" "[$level] $message"
    echo "[$timestamp] [$level] $message" >> "$LOG_FILE"
    
    case $level in
        "ERROR"|"CRITICAL")
            echo -e "${COLORS[RED]}$message${COLORS[NC]}" >&2
            ;;
        "WARNING")
            echo -e "${COLORS[YELLOW]}$message${COLORS[NC]}"
            ;;
        *)
            echo -e "${COLORS[GREEN]}$message${COLORS[NC]}"
            ;;
    esac
}

# --- 检测IPv6连通性 ---
check_ipv6_connectivity() {
    if "$PING6_CMD" -q -c "$COUNT" -W "$PING_TIMEOUT" "$TARGET" &> /dev/null; then
        return 0
    else
        return 1
    fi
}

# --- 获取IPv6丢包率 ---
get_ipv6_loss_rate() {
    local loss=$("$PING6_CMD" -q -c "$COUNT" -W "$PING_TIMEOUT" "$TARGET" 2>/dev/null |
                grep -oP '\d+(?=% packet loss)' || echo "100")
    echo "$loss"
}

# --- 重置WARP出口 ---
reset_warp() {
    local endpoint_to_use="${FALLBACK_ENDPOINTS[0]}"
    local current_endpoint=$(grep "Endpoint" "$WARP_CONFIG" | cut -d'=' -f2 | tr -d '[:space:]')
    
    log_message "INFO" "开始重置WARP出口..."

    if ! "$WG_QUICK_CMD" down warp &>> "$LOG_FILE"; then
        log_message "ERROR" "关闭WARP接口失败"
        return 1
    fi
    
    local next_endpoint=""
    local current_index=0
    for i in "${!FALLBACK_ENDPOINTS[@]}"; do
        if [[ "${FALLBACK_ENDPOINTS[$i]}" == "$current_endpoint" ]]; then
            current_index=$i
            break
        fi
    done
    
    local next_index=$(((current_index + 1) % ${#FALLBACK_ENDPOINTS[@]}))
    next_endpoint="${FALLBACK_ENDPOINTS[$next_index]}"

    log_message "INFO" "切换到新的Endpoint地址: $next_endpoint"
    if ! sed -i "s|Endpoint.*|Endpoint = $next_endpoint|" "$WARP_CONFIG"; then
        log_message "ERROR" "修改WARP配置文件失败"
        return 1
    fi
    
    if ! "$WARP_CMD" o &>> "$LOG_FILE"; then
        log_message "ERROR" "重新启用WARP失败"
        return 1
    fi
    
    log_message "INFO" "WARP 出口重置完成"
    return 0
}

# --- 显示网络状态 ---
show_network_status() {
    local loss=$(get_ipv6_loss_rate)
    local status
    
    if [[ "$loss" -eq "100" ]]; then
        status="${COLORS[RED]}断开连接${COLORS[NC]}"
    elif [[ "$loss" -gt "20" ]]; then
        status="${COLORS[YELLOW]}不稳定 (丢包率 ${loss}%)${COLORS[NC]}"
    else
        status="${COLORS[GREEN]}正常 (丢包率 ${loss}%)${COLORS[NC]}"
    fi
    
    echo -e "当前IPv6网络状态: $status"
    echo -e "目标服务器: $TARGET"
    echo -e "测试次数: $COUNT"
    echo -e "超时设置: ${PING_TIMEOUT}秒"
}

# --- 主程序 ---
main() {
    init

    echo -e "${COLORS[YELLOW]}===============================================${COLORS[NC]}"
    echo -e "${COLORS[YELLOW]}      WARP IPv6出口自动恢复脚本启动      ${COLORS[NC]}"
    echo -e "${COLORS[YELLOW]}===============================================${COLORS[NC]}"
    
    show_network_status
    
    if check_ipv6_connectivity; then
        local loss=$(get_ipv6_loss_rate)
        log_message "INFO" "IPv6网络连通正常 (丢包率 ${loss}%)"
        exit 0
    fi
    
    local retry_count=0
    while [[ $retry_count -lt $MAX_RETRY ]]; do
        retry_count=$((retry_count + 1))
        local loss=$(get_ipv6_loss_rate)
        
        log_message "WARNING" "[尝试 $retry_count/$MAX_RETRY] IPv6网络中断 (丢包率 ${loss}%)"
        
        if reset_warp; then
            log_message "INFO" "等待 ${SLEEP_INTERVAL} 秒让网络稳定..."
            sleep "$SLEEP_INTERVAL"
            
            if check_ipv6_connectivity; then
                loss=$(get_ipv6_loss_rate)
                log_message "INFO" "IPv6网络已恢复 (丢包率 ${loss}%)"
                show_network_status
                exit 0
            fi
        fi
    done
    
    log_message "ERROR" "已达到最大重试次数，IPv6网络仍未恢复"
    show_network_status
    exit 1
}

main