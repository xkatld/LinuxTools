#!/bin/bash

set -euo pipefail

readonly SWAP_FILE_PATH="/swapfile"

log_info() { echo "[INFO] $1"; }
log_ok() { echo "[OK] $1"; }
log_error() { echo "[ERROR] $1" >&2; }
log_warn() { echo "[WARN] $1"; }

show_memory_info() {
    local mem_total mem_used mem_available usage_percent
    mem_total=$(free -m | awk '/^Mem:/{print $2}')
    mem_used=$(free -m | awk '/^Mem:/{print $3}')
    mem_available=$(free -m | awk '/^Mem:/{print $NF}')
    
    mem_total=${mem_total:-1}
    mem_used=${mem_used:-0}
    mem_available=${mem_available:-0}
    usage_percent=$((mem_used * 100 / mem_total))
    
    echo "当前内存状态:"
    echo "  总量: ${mem_total}MB | 已用: ${mem_used}MB (${usage_percent}%) | 可用: ${mem_available}MB"
}

calculate_zram_recommendation() {
    local mem_mb=$1
    local recommended
    
    if [[ $mem_mb -le 1024 ]]; then
        recommended=$((mem_mb * 2))
        echo "$recommended|≤1GB 内存，推荐 200% (压缩比约2-4:1，实际占用较小)"
    elif [[ $mem_mb -le 4096 ]]; then
        recommended=$((mem_mb * 3 / 2))
        echo "$recommended|1-4GB 内存，推荐 150% (有效扩展可用内存)"
    elif [[ $mem_mb -le 16384 ]]; then
        recommended=$mem_mb
        echo "$recommended|4-16GB 内存，推荐 100% (平衡性能与扩展)"
    else
        recommended=$((mem_mb / 2))
        [[ $recommended -gt 16384 ]] && recommended=16384
        echo "$recommended|>16GB 内存，推荐 50% (最大16GB)"
    fi
}

calculate_swap_recommendation() {
    local mem_mb=$1
    local disk_available_mb=$2
    local recommended reason
    
    if [[ $mem_mb -le 2048 ]]; then
        recommended=$((mem_mb * 2))
        reason="≤2GB 内存，推荐 2x 内存"
    elif [[ $mem_mb -le 8192 ]]; then
        recommended=$mem_mb
        reason="2-8GB 内存，推荐 1x 内存"
    else
        recommended=4096
        reason=">8GB 内存，推荐固定 4GB"
    fi
    
    if [[ "$disk_available_mb" =~ ^[0-9]+$ ]] && [[ $disk_available_mb -gt 0 ]]; then
        local max_swap=$((disk_available_mb / 2))
        if [[ $recommended -gt $max_swap ]]; then
            recommended=$max_swap
            reason="${reason} (受磁盘空间限制: ${max_swap}MB)"
        fi
    fi
    
    echo "$recommended|$reason"
}

apply_aggressive_swap_settings() {
    local sysctl_file="/etc/sysctl.d/99-swap-tuning.conf"
    
    log_info "应用最激进虚拟内存策略..."
    
    cat > "$sysctl_file" << 'EOF'
vm.swappiness = 200
vm.vfs_cache_pressure = 500
vm.page-cluster = 0
EOF
    
    sysctl -p "$sysctl_file" >/dev/null 2>&1
    log_ok "内核参数已优化: swappiness=200, vfs_cache_pressure=500, page-cluster=0"
}

remove_swap_settings() {
    local sysctl_file="/etc/sysctl.d/99-swap-tuning.conf"
    if [[ -f "$sysctl_file" ]]; then
        rm -f "$sysctl_file"
        sysctl --system >/dev/null 2>&1
        log_info "已清理内核参数配置"
    fi
}

initial_checks() {
    if [[ "${EUID}" -ne 0 ]]; then
        log_error "需要 root 权限"
        exit 1
    fi

    if [[ -d "/proc/vz" ]]; then
        log_error "不支持 OpenVZ 虚拟化环境"
        exit 1
    fi

    local dependencies=("free" "grep" "sed" "awk" "systemctl" "dpkg" "apt-get" "modprobe")
    for cmd in "${dependencies[@]}"; do
        if ! command -v "$cmd" &>/dev/null; then
            log_error "缺少命令: $cmd"
            exit 1
        fi
    done
}

show_status() {
    echo ""
    echo "=> 当前虚拟内存状态"
    echo ""
    echo "Swap 摘要:"
    swapon --summary 2>/dev/null || echo "  -> 无活动 Swap"
    echo ""
    echo "内存使用:"
    free -h
    echo "========================================"
}

detect_zram_service() {
    if [[ -f /lib/systemd/system/zramswap.service ]]; then
        echo "/etc/default/zramswap zramswap.service"
    elif [[ -f /lib/systemd/system/zram-config.service ]]; then
        echo "/etc/default/zram-config zram-config.service"
    else
        echo ""
    fi
}

check_zram_support() {
    if modprobe --dry-run zram &>/dev/null; then
        return 0
    else
        log_error "内核不支持 ZRAM 模块"
        return 1
    fi
}

configure_zram() {
    echo ""
    echo "=> 配置 ZRAM"
    echo ""
    
    if ! check_zram_support; then
        log_warn "请使用 Swap 文件功能"
        return 1
    fi

    log_info "安装 zram-tools..."
    DEBIAN_FRONTEND=noninteractive apt-get update -y >/dev/null && apt-get install -y zram-tools
    systemctl daemon-reload

    local zram_details
    zram_details=$(detect_zram_service)
    if [[ -z "$zram_details" ]]; then
        log_error "未检测到 ZRAM 服务"
        return 1
    fi

    local config_file service_name
    read -r config_file service_name <<< "$zram_details"
    log_info "检测到服务: $service_name"

    local physical_mem
    physical_mem=$(free -m | awk '/^Mem:/{print $2}')
    
    echo ""
    show_memory_info
    echo ""
    
    local recommendation
    recommendation=$(calculate_zram_recommendation "$physical_mem")
    local default_zram="${recommendation%%|*}"
    local recommend_reason="${recommendation#*|}"
    
    log_info "科学推荐: ${default_zram}MB"
    log_info "理由: ${recommend_reason}"
    echo ""

    local zram_size
    while true; do
        read -p "ZRAM 大小 (MB) [推荐: ${default_zram}]: " -r zram_size
        zram_size=${zram_size:-$default_zram}
        if [[ "$zram_size" =~ ^[1-9][0-9]*$ ]]; then
            break
        else
            log_error "请输入有效数字"
        fi
    done

    echo ""
    echo "压缩算法:"
    echo "  1) zstd (推荐，压缩比高)"
    echo "  2) lz4  (速度最快，CPU开销小)"
    echo "  3) lzo  (传统默认，兼容性好)"
    local algo_choice zram_algo
    read -p "选择 [默认: 1]: " -r algo_choice
    algo_choice=${algo_choice:-1}
    case "$algo_choice" in
        2) zram_algo="lz4" ;;
        3) zram_algo="lzo" ;;
        *) zram_algo="zstd" ;;
    esac
    log_info "已选择压缩算法: ${zram_algo}"

    log_info "清理现有 ZRAM..."
    systemctl stop "$service_name" 2>/dev/null || true
    systemctl disable "$service_name" 2>/dev/null || true
    for zdev in /dev/zram*; do
        if [[ -b "$zdev" ]]; then
            swapoff "$zdev" 2>/dev/null || true
            zramctl --reset "$zdev" 2>/dev/null || true
        fi
    done
    rmmod zram 2>/dev/null || true
    sleep 1
    
    log_info "创建 ${zram_size}MB ZRAM..."
    modprobe zram num_devices=1
    local zram_dev
    zram_dev=$(zramctl --find --size "${zram_size}M" --algorithm "${zram_algo}")
    
    if [[ -z "$zram_dev" ]]; then
        log_error "ZRAM 设备创建失败"
        return 1
    fi
    
    mkswap "$zram_dev"
    swapon -p 32767 "$zram_dev"
    
    log_info "写入开机配置..."
    cat > "$config_file" << EOF
ALGO=${zram_algo}
PERCENT=$((zram_size * 100 / physical_mem))
PRIORITY=32767
EOF
    systemctl enable "$service_name" 2>/dev/null || true

    log_ok "ZRAM 已配置: ${zram_dev} (${zram_size}MB, ${zram_algo}, 优先级32767)"
    apply_aggressive_swap_settings
}

remove_zram() {
    echo ""
    echo "=> 移除 ZRAM"
    echo ""
    
    local zram_details
    zram_details=$(detect_zram_service)

    if [[ -z "$zram_details" ]] && ! dpkg -s "zram-tools" &>/dev/null; then
        log_error "未检测到 ZRAM"
        return 1
    fi

    read -p "确认移除 ZRAM? [y/N]: " -r confirm
    confirm=${confirm:-N}
    if [[ ! "${confirm}" =~ ^[yY]$ ]]; then
        log_info "已取消"
        return
    fi

    if [[ -n "$zram_details" ]]; then
        local service_name
        service_name=$(echo "$zram_details" | awk '{print $2}')
        if systemctl is-active --quiet "$service_name"; then
            log_info "停止服务..."
            systemctl stop "$service_name"
            systemctl disable "$service_name"
        fi
    fi

    if dpkg -s "zram-tools" &>/dev/null; then
        log_info "卸载 zram-tools..."
        apt-get purge -y zram-tools >/dev/null
    fi
    
    remove_swap_settings
    log_ok "ZRAM 已移除"
}

create_swap_file() {
    echo ""
    echo "=> 创建 Swap 文件"
    echo ""
    
    if [[ -f "${SWAP_FILE_PATH}" ]] || grep -q "${SWAP_FILE_PATH}" /etc/fstab; then
        log_error "Swap 文件已存在"
        return 1
    fi

    local physical_mem
    physical_mem=$(free -m | awk '/^Mem:/{print $2}')
    
    local swap_dir
    swap_dir=$(dirname "${SWAP_FILE_PATH}")
    local disk_available_mb
    disk_available_mb=$(df -m "$swap_dir" 2>/dev/null | awk 'NR==2{print $4}' || echo "0")
    
    echo ""
    show_memory_info
    log_info "磁盘可用空间: ${disk_available_mb}MB (${swap_dir})"
    echo ""
    
    local recommendation
    recommendation=$(calculate_swap_recommendation "$physical_mem" "$disk_available_mb")
    local default_swap="${recommendation%%|*}"
    local recommend_reason="${recommendation#*|}"
    
    log_info "科学推荐: ${default_swap}MB"
    log_info "理由: ${recommend_reason}"
    echo ""

    local swap_size
    while true; do
        read -p "Swap 大小 (MB) [推荐: ${default_swap}]: " -r swap_size
        swap_size=${swap_size:-$default_swap}
        if [[ "$swap_size" =~ ^[1-9][0-9]*$ ]]; then
            break
        else
            log_error "请输入有效数字"
        fi
    done

    log_info "创建 ${swap_size}MB Swap 文件..."
    if ! fallocate -l "${swap_size}M" "${SWAP_FILE_PATH}" 2>/dev/null; then
        log_warn "fallocate 失败，使用 dd 创建..."
        dd if=/dev/zero of="${SWAP_FILE_PATH}" bs=1M count="${swap_size}" status=progress
    fi
    chmod 600 "${SWAP_FILE_PATH}"
    mkswap "${SWAP_FILE_PATH}"
    swapon "${SWAP_FILE_PATH}"
    
    log_info "写入 /etc/fstab..."
    echo "${SWAP_FILE_PATH} none swap sw 0 0" >> /etc/fstab

    log_ok "Swap 文件已创建并启用"
    apply_aggressive_swap_settings
}

remove_swap_file() {
    echo ""
    echo "=> 移除 Swap 文件"
    echo ""
    
    if ! grep -q "${SWAP_FILE_PATH}" /etc/fstab && [[ ! -f "${SWAP_FILE_PATH}" ]]; then
        log_error "未找到 Swap 文件"
        return 1
    fi

    read -p "确认删除 Swap 文件? [y/N]: " -r confirm
    confirm=${confirm:-N}
    if [[ ! "${confirm}" =~ ^[yY]$ ]]; then
        log_info "已取消"
        return
    fi

    log_info "禁用并移除配置..."
    swapoff "${SWAP_FILE_PATH}" 2>/dev/null || true
    sed -i.bak "\#${SWAP_FILE_PATH}#d" /etc/fstab

    log_info "删除文件..."
    rm -f "${SWAP_FILE_PATH}"
    
    remove_swap_settings
    log_ok "Swap 文件已移除"
}

main_menu() {
    while true; do
        clear 2>/dev/null || printf '\033[2J\033[H'
        
        echo "========================================"
        echo "  虚拟内存管理"
        echo "========================================"
        show_status
        echo ""
        echo "ZRAM (内存压缩):"
        echo "  1) 配置 ZRAM"
        echo "  2) 移除 ZRAM"
        echo ""
        echo "Swap 文件 (硬盘):"
        echo "  3) 创建 Swap 文件"
        echo "  4) 移除 Swap 文件"
        echo ""
        echo "  0) 退出"
        echo "========================================"
        read -p "请选择 [0-4]: " -r choice

        case "$choice" in
            1) configure_zram ;;
            2) remove_zram ;;
            3) create_swap_file ;;
            4) remove_swap_file ;;
            0) log_info "退出脚本"; exit 0 ;;
            *) log_error "无效选项: $choice" ;;
        esac
        echo ""
        read -n 1 -s -r -p "按任意键返回主菜单..."
    done
}

initial_checks
main_menu
