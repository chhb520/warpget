#!/usr/bin/env bash

# =============================================
# 优化版 WARP IPv4 & IPv6 出口自动恢复脚本
# =============================================

# --- 全局配置 ---
readonly TARGET_V4="1.1.1.1"               # Ping 测试目标 (IPv4)
readonly TARGET_V6="2606:4700:4700::1111"  # Ping 测试目标 (IPv6)
readonly COUNT=5                           # Ping 次数
readonly PING_TIMEOUT=3                    # Ping 超时(秒)
readonly SLEEP_INTERVAL=10                 # 重试间隔(秒)
readonly MAX_RETRY=3                       # 最大重试次数
readonly LOCK_FILE="/tmp/warp_monitor_all.lock" # 锁文件路径
readonly LOG_FILE="/var/log/warp_monitor_all.log" # 日志文件路径
readonly WARP_CONFIG="/etc/wireguard/warp.conf" # WARP 配置文件路径

# 备用 WARP Endpoint
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
        echo -e "${COLORS[RED]}错误: 此脚本需要root权限。请使用 sudo 执行。${COLORS[NC]}" >&2
        exit 1
    fi
}

# --- 查找关键命令路径 ---
find_commands() {
    readonly PING_CMD=$(which ping)
    readonly PING6_CMD=$(which ping6)
    readonly WG_QUICK_CMD=$(which wg-quick)
    readonly WARP_CMD=$(which warp)

    if [[ -z "$PING_CMD" || -z "$PING6_CMD" || -z "$WG_QUICK_CMD" || -z "$WARP_CMD" ]]; then
        echo -e "${COLORS[RED]}错误: 找不到必要的命令，请确保已安装 ping, ping6, wg-quick 和 warp。${COLORS[NC]}" >&2
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
    log_message "INFO" "脚本执行结束，已清理琐碎文件"
    echo -e "\n${COLORS[CYAN]}脚本执行完成${COLORS[NC]}"
}

# --- 日志记录函数 ---
log_message() {
    local level=$1
    local message=$2
    local timestamp=$(date "+%Y-%m-%d %H:%M:%S")

    logger -t "WARP_Monitor" "[$level] $message"
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

# --- 检测IPv4连通性 ---
check_ipv4_connectivity() {
    "$PING_CMD" -4 -q -c "$COUNT" -W "$PING_TIMEOUT" "$TARGET_V4" &> /dev/null
}

# --- 检测IPv6连通性 ---
check_ipv6_connectivity() {
    "$PING6_CMD" -q -c "$COUNT" -W "$PING_TIMEOUT" "$TARGET_V6" &> /dev/null
}

# --- 获取丢包率 ---
get_loss_rate() {
    local ip_version=$1
    local target=""
    local ping_cmd=""

    if [[ "$ip_version" == "v4" ]]; then
        target="$TARGET_V4"
        ping_cmd="$PING_CMD -4"
    else
        target="$TARGET_V6"
        ping_cmd="$PING6_CMD"
    fi

    local loss=$(eval "$ping_cmd -q -c $COUNT -W $PING_TIMEOUT $target" 2>/dev/null |
                grep -oP '\d+(?=% packet loss)' || echo "100")
    echo "$loss"
}

# --- 重置WARP出口 ---
reset_warp() {
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
    local loss_v4=$(get_loss_rate "v4")
    local loss_v6=$(get_loss_rate "v6")
    
    local status_v4="${COLORS[RED]}断开连接${COLORS[NC]}"
    if [[ "$loss_v4" -le "20" ]]; then
        status_v4="${COLORS[GREEN]}正常 (丢包率 ${loss_v4}%)${COLORS[NC]}"
    elif [[ "$loss_v4" -gt "20" && "$loss_v4" -lt "100" ]]; then
        status_v4="${COLORS[YELLOW]}不稳定 (丢包率 ${loss_v4}%)${COLORS[NC]}"
    fi

    local status_v6="${COLORS[RED]}断开连接${COLORS[NC]}"
    if [[ "$loss_v6" -le "20" ]]; then
        status_v6="${COLORS[GREEN]}正常 (丢包率 ${loss_v6}%)${COLORS[NC]}"
    elif [[ "$loss_v6" -gt "20" && "$loss_v6" -lt "100" ]]; then
        status_v6="${COLORS[YELLOW]}不稳定 (丢包率 ${loss_v6}%)${COLORS[NC]}"
    fi

    echo -e "当前网络状态："
    echo -e "  IPv4: $status_v4"
    echo -e "  IPv6: $status_v6"
    echo -e "测试目标: IPv4(${TARGET_V4}) / IPv6(${TARGET_V6})"
    echo -e "超时设置: ${PING_TIMEOUT}秒 | 测试次数: ${COUNT}"
}

# --- 主程序 ---
main() {
    init

    echo -e "${COLORS[YELLOW]}===============================================${COLORS[NC]}"
    echo -e "${COLORS[YELLOW]} WARP IPv4 & IPv6 统一监控与恢复脚本启动 ${COLORS[NC]}"
    echo -e "${COLORS[YELLOW]}===============================================${COLORS[NC]}"

    show_network_status
    
    local connected_v4=false
    local connected_v6=false

    check_ipv4_connectivity && connected_v4=true
    check_ipv6_connectivity && connected_v6=true

    if $connected_v4 && $connected_v6; then
        log_message "INFO" "IPv4和IPv6网络均连通正常，无需重置。"
        exit 0
    elif ! $connected_v4 && ! $connected_v6; then
        log_message "WARNING" "IPv4和IPv6网络均已断开，无法通过重置解决。"
        exit 0
    fi
    
    # 以下为有一个不通，进行重试和重置的逻辑
    local retry_count=0
    while [[ $retry_count -lt $MAX_RETRY ]]; do
        retry_count=$((retry_count + 1))
        
        log_message "WARNING" "[尝试 $retry_count/$MAX_RETRY] 检测到部分网络中断，正在尝试重置 WARP..."
        
        if reset_warp; then
            log_message "INFO" "等待 ${SLEEP_INTERVAL} 秒让网络稳定..."
            sleep "$SLEEP_INTERVAL"
            
            check_ipv4_connectivity && connected_v4=true || connected_v4=false
            check_ipv6_connectivity && connected_v6=true || connected_v6=false

            if $connected_v4 && $connected_v6; then
                log_message "INFO" "IPv4和IPv6网络已恢复连通。"
                show_network_status
                exit 0
            fi
        fi
    done
    
    log_message "ERROR" "已达到最大重试次数，部分网络仍未恢复。"
    show_network_status
    exit 1
}

main