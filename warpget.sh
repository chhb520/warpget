
#!/usr/bin/env bash

# =============================================
# 优化版 WARP IPv4 出口自动恢复脚本
# =============================================

# --- 全局配置 ---
readonly TARGET="1.1.1.1"          # Ping 测试目标 (IPv4)
readonly COUNT=5                   # Ping 次数
readonly PING_TIMEOUT=3            # Ping 超时(秒)
readonly SLEEP_INTERVAL=10         # 重试间隔(秒)
readonly MAX_RETRY=3               # 最大重试次数
readonly LOCK_FILE="/tmp/warp_monitor.lock"  # 锁文件路径
readonly LOG_FILE="/var/log/warp_monitor.log" # 日志文件路径
readonly WARP_CONFIG="/etc/wireguard/warp.conf" # WARP 配置文件路径

# --- 颜色配置 ---
declare -A COLORS=(
    [RED]="\033[0;31m"
    [GREEN]="\033[0;32m"
    [YELLOW]="\033[1;33m"
    [BLUE]="\033[0;34m"
    [CYAN]="\033[0;36m"
    [NC]="\033[0m"
)

# --- 日志级别 ---
declare -A LOG_LEVELS=(
    [INFO]=0
    [WARNING]=1
    [ERROR]=2
    [CRITICAL]=3
)

# --- 初始化 ---
init() {
    check_root
    setup_logging
    check_lock
    create_lock
    set_traps
}

# --- 检查root权限 ---
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_message "ERROR" "此脚本需要root权限" >&2
        echo -e "${COLORS[RED]}错误: 请使用 sudo 执行此脚本${COLORS[NC]}" >&2
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
            log_message "WARNING" "脚本已在运行中 (PID: $pid)"
            echo -e "${COLORS[YELLOW]}警告: 脚本已在运行中${COLORS[NC]}" >&2
            exit 1
        else
            log_message "WARNING" "发现陈旧的锁文件，已清除"
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
    
    # 写入系统日志
    logger -t "WARP_Monitor" "[$level] $message"
    
    # 写入日志文件
    echo "[$timestamp] [$level] $message" >> "$LOG_FILE"
    
    # 控制台输出
    case $level in
        "ERROR"|"CRITICAL")
            echo -e "${COLORS[RED]}[$timestamp] [$level] $message${COLORS[NC]}" >&2
            ;;
        "WARNING")
            echo -e "${COLORS[YELLOW]}[$timestamp] [$level] $message${COLORS[NC]}"
            ;;
        *)
            echo -e "${COLORS[GREEN]}[$timestamp] [$level] $message${COLORS[NC]}"
            ;;
    esac
}

# --- 检测IPv4连通性 ---
check_ipv4_connectivity() {
    if ping -4 -q -c "$COUNT" -W "$PING_TIMEOUT" "$TARGET" &> /dev/null; then
        return 0
    else
        return 1
    fi
}

# --- 获取丢包率 ---
get_loss_rate() {
    local loss=$(ping -4 -q -c "$COUNT" -W "$PING_TIMEOUT" "$TARGET" 2>/dev/null | 
                grep -oP '\d+(?=% packet loss)' || echo "100")
    echo "$loss"
}

# --- 重置WARP v4出口 ---
reset_warp_v4() {
    log_message "INFO" "开始重置WARP v4出口..."
    
    # 关闭WARP接口
    if ! wg-quick down warp &>> "$LOG_FILE"; then
        log_message "ERROR" "关闭WARP接口失败"
        return 1
    fi
    
    # 修改配置文件
    if ! sed -i "s/Endpoint.*/Endpoint = engage.cloudflareclient.com:4500/" "$WARP_CONFIG"; then
        log_message "ERROR" "修改WARP配置文件失败"
        return 1
    fi
    
    # 重新启用WARP
    if ! warp o &>> "$LOG_FILE"; then
        log_message "ERROR" "重新启用WARP失败"
        return 1
    fi
    
    log_message "INFO" "WARP v4出口重置完成"
    return 0
}

# --- 显示网络状态 ---
show_network_status() {
    local loss=$(get_loss_rate)
    local status
    
    if [[ "$loss" -eq "100" ]]; then
        status="${COLORS[RED]}断开连接${COLORS[NC]}"
    elif [[ "$loss" -gt "20" ]]; then
        status="${COLORS[YELLOW]}不稳定 (丢包率 ${loss}%)${COLORS[NC]}"
    else
        status="${COLORS[GREEN]}正常 (丢包率 ${loss}%)${COLORS[NC]}"
    fi
    
    echo -e "当前网络状态: $status"
    echo -e "目标服务器: $TARGET"
    echo -e "测试次数: $COUNT"
    echo -e "超时设置: ${PING_TIMEOUT}秒"
}

# --- 主程序 ---
main() {
    init
    
    log_message "INFO" "========== WARP IPv4出口监控启动 =========="
    echo -e "${COLORS[BLUE]}===============================================${COLORS[NC]}"
    echo -e "${COLORS[BLUE]}      WARP IPv4出口自动恢复脚本启动${COLORS[NC]}"
    echo -e "${COLORS[BLUE]}===============================================${COLORS[NC]}"
    
    show_network_status
    
    # 首次检查
    if check_ipv4_connectivity; then
        local loss=$(get_loss_rate)
        log_message "INFO" "IPv4网络连通正常 (丢包率 ${loss}%)"
        exit 0
    fi
    
    # 重试循环
    local retry_count=0
    while [[ $retry_count -lt $MAX_RETRY ]]; do
        retry_count=$((retry_count + 1))
        local loss=$(get_loss_rate)
        
        log_message "WARNING" "[尝试 $retry_count/$MAX_RETRY] IPv4网络中断 (丢包率 ${loss}%)"
        
        if reset_warp_v4; then
            log_message "INFO" "等待 ${SLEEP_INTERVAL} 秒让网络稳定..."
            sleep "$SLEEP_INTERVAL"
            
            if check_ipv4_connectivity; then
                loss=$(get_loss_rate)
                log_message "INFO" "IPv4网络已恢复 (丢包率 ${loss}%)"
                show_network_status
                exit 0
            fi
        fi
    done
    
    # 达到最大重试次数
    log_message "ERROR" "已达到最大重试次数，IPv4网络仍未恢复"
    show_network_status
    exit 1
}

# --- 执行主程序 ---
main
