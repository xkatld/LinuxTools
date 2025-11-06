#!/bin/bash

set -euo pipefail

readonly SWAP_FILE_PATH="/swapfile"

log_info() { echo "[INFO] $1"; }
log_ok() { echo "[OK] $1"; }
log_error() { echo "[ERROR] $1" >&2; }
log_warn() { echo "[WARN] $1"; }

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
    local default_zram=$((physical_mem / 2))

    local zram_size
    while true; do
        read -p "ZRAM 大小 (MB) [默认: ${default_zram}]: " -r zram_size
        zram_size=${zram_size:-$default_zram}
        if [[ "$zram_size" =~ ^[1-9][0-9]*$ ]]; then
            break
        else
            log_error "请输入有效数字"
        fi
    done

    log_info "写入配置..."
    echo -e "ALGO=zstd\nSIZE=${zram_size}" > "$config_file"

    log_info "重启服务..."
    if systemctl restart "$service_name"; then
        log_ok "ZRAM 已配置并启用"
    else
        log_error "服务启动失败"
        return 1
    fi
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
    
    log_ok "ZRAM 已移除"
}

create_swap_file() {
    echo ""
    echo "=> 创建 Swap 文件"
    echo ""
    
    if grep -q "${SWAP_FILE_PATH}" /etc/fstab; then
        log_error "Swap 文件已存在"
        return 1
    fi

    local physical_mem
    physical_mem=$(free -m | awk '/^Mem:/{print $2}')
    local default_swap=$((physical_mem * 2))

    local swap_size
    while true; do
        read -p "Swap 大小 (MB) [默认: ${default_swap}]: " -r swap_size
        swap_size=${swap_size:-$default_swap}
        if [[ "$swap_size" =~ ^[1-9][0-9]*$ ]]; then
            break
        else
            log_error "请输入有效数字"
        fi
    done

    log_info "创建 ${swap_size}MB Swap 文件..."
    fallocate -l "${swap_size}M" "${SWAP_FILE_PATH}"
    chmod 600 "${SWAP_FILE_PATH}"
    mkswap "${SWAP_FILE_PATH}"
    swapon "${SWAP_FILE_PATH}"
    
    log_info "写入 /etc/fstab..."
    echo "${SWAP_FILE_PATH} none swap sw 0 0" >> /etc/fstab

    log_ok "Swap 文件已创建并启用"
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
