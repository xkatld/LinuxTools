#!/bin/bash

set -o errexit
set -o nounset
set -o pipefail

readonly SWAP_FILE_PATH="/swapfile"

readonly COLOR_GREEN='\033[0;32m'
readonly COLOR_YELLOW='\033[1;33m'
readonly COLOR_RED='\033[0;31m'
readonly COLOR_BLUE='\033[0;34m'
readonly COLOR_NC='\033[0m'

msg() {
    local color_name="$1"
    local message="$2"
    local color_var="COLOR_${color_name^^}"
    echo -e "${!color_var}${message}${COLOR_NC}"
}

initial_checks() {
    if [[ "${EUID}" -ne 0 ]]; then
        msg "RED" "错误：此脚本需要 root 权限才能修改系统设置。"
        exit 1
    fi

    if [[ -d "/proc/vz" ]]; then
        msg "RED" "错误：不支持 OpenVZ 虚拟化环境，因为它无法修改内核和 Swap。"
        exit 1
    fi

    local dependencies=("free" "grep" "sed" "awk" "systemctl" "dpkg" "apt-get" "modprobe")
    for cmd in "${dependencies[@]}"; do
        if ! command -v "$cmd" &> /dev/null; then
            msg "RED" "错误: 缺少核心命令 '$cmd'，请先安装它。"
            exit 1
        fi
    done
}

show_status() {
    msg "BLUE" "--- 当前系统虚拟内存状态 ---"
    echo "Swap 摘要:"
    swapon --summary || msg "YELLOW" "  -> 当前没有活动的 Swap 设备。"
    echo ""
    echo "内存使用情况:"
    free -h
    echo "------------------------------------"
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

check_zram_module_support() {
    msg "YELLOW" "正在检查内核是否支持 ZRAM 模块..."
    if modprobe --dry-run zram &>/dev/null; then
        msg "GREEN" "✓ 内核支持 ZRAM 模块。"
        return 0
    else
        msg "RED" "错误: 您当前的内核 ($(uname -r)) 似乎不支持 ZRAM 模块。"
        msg "YELLOW" "这在某些云厂商提供的定制内核中很常见。"
        msg "YELLOW" "请考虑使用本脚本中的 Swap 文件功能作为替代，或更换为标准的 Linux 内核。"
        return 1
    fi
}

configure_zram() {
    msg "BLUE" "--- [ZRAM] 安装并配置 ZRAM ---"
    if ! check_zram_module_support; then
        return 1
    fi

    msg "YELLOW" "正在安装 zram-tools (若未安装)..."
    DEBIAN_FRONTEND=noninteractive apt-get update -y >/dev/null && apt-get install -y zram-tools

    local zram_details
    zram_details=$(detect_zram_service)
    if [[ -z "$zram_details" ]]; then
        msg "RED" "错误: 安装 zram-tools 后，未能侦测到任何已知的 ZRAM 服务。无法继续。"
        return 1
    fi

    local config_file service_name
    read -r config_file service_name <<< "$zram_details"
    msg "GREEN" "侦测到 ZRAM 服务: $service_name"

    local zram_size
    while true; do
        read -p "请输入 ZRAM 大小 (MB, 推荐值为物理内存的50%-100%): " zram_size
        if [[ "$zram_size" =~ ^[1-9][0-9]*$ ]]; then
            break
        else
            msg "RED" "输入无效，请输入一个正整数。"
        fi
    done

    msg "YELLOW" "正在向 '$config_file' 写入配置..."
    echo -e "ALGO=zstd\nSIZE=${zram_size}" > "$config_file"

    msg "YELLOW" "正在重启 ZRAM 服务 ($service_name) 以应用配置..."
    if systemctl restart "$service_name"; then
        echo ""
        msg "GREEN" "✓ ZRAM 已成功配置并启用！"
    else
        echo ""
        msg "RED" "ZRAM 服务启动失败。请运行 'systemctl status $service_name' 和 'journalctl -xeu $service_name' 查看详细错误。"
        return 1
    fi
}

remove_zram() {
    msg "BLUE" "--- [ZRAM] 移除 ZRAM ---"
    local zram_details
    zram_details=$(detect_zram_service)

    if [[ -z "$zram_details" ]] && ! dpkg -s "zram-tools" &>/dev/null; then
        msg "RED" "错误: 未检测到 ZRAM 服务或 zram-tools 包，无需移除。"
        return 1
    fi

    msg "RED" "警告：此操作将停止 ZRAM 服务并卸载 zram-tools 包！"
    read -p "$(echo -e "${COLOR_YELLOW}您确定要继续吗? [y/N]: ${COLOR_NC}")" confirm
    if [[ ! "${confirm}" =~ ^[yY]$ ]]; then
        msg "BLUE" "操作已由用户取消。"
        return
    fi

    if [[ -n "$zram_details" ]]; then
        local service_name
        service_name=$(echo "$zram_details" | awk '{print $2}')
        if systemctl is-active --quiet "$service_name"; then
            msg "YELLOW" "正在停止并禁用服务: $service_name..."
            systemctl stop "$service_name"
            systemctl disable "$service_name"
        fi
    fi

    if dpkg -s "zram-tools" &>/dev/null; then
        msg "YELLOW" "正在卸载 zram-tools 并清理配置..."
        apt-get purge -y zram-tools >/dev/null
    fi
    
    echo ""
    msg "GREEN" "✓ ZRAM 已成功移除！"
}

create_swap_file() {
    msg "BLUE" "--- [Swap文件] 添加 Swap 文件 ---"
    if grep -q "${SWAP_FILE_PATH}" /etc/fstab; then
        msg "RED" "错误: Swap 文件 '${SWAP_FILE_PATH}' 的配置已存在于 /etc/fstab。"
        return 1
    fi

    local swap_size
    while true; do
        read -p "请输入 Swap 文件大小 (MB, 推荐值为物理内存的1-2倍): " swap_size
        if [[ "$swap_size" =~ ^[1-9][0-9]*$ ]]; then
            break
        else
            msg "RED" "输入无效，请输入一个正整数。"
        fi
    done

    msg "YELLOW" "正在创建 ${swap_size}MB 的 Swap 文件于 '${SWAP_FILE_PATH}'..."
    fallocate -l "${swap_size}M" "${SWAP_FILE_PATH}"
    chmod 600 "${SWAP_FILE_PATH}"
    mkswap "${SWAP_FILE_PATH}"
    swapon "${SWAP_FILE_PATH}"
    
    msg "YELLOW" "正在将 Swap 配置写入 /etc/fstab 以便开机自启..."
    echo "${SWAP_FILE_PATH} none swap sw 0 0" >> /etc/fstab

    echo ""
    msg "GREEN" "✓ Swap 文件已成功创建并启用！"
}

remove_swap_file() {
    msg "BLUE" "--- [Swap文件] 移除 Swap 文件 ---"
    if ! grep -q "${SWAP_FILE_PATH}" /etc/fstab && [ ! -f "${SWAP_FILE_PATH}" ]; then
        msg "RED" "错误: 未找到 Swap 文件或其配置，无需移除。"
        return 1
    fi

    msg "RED" "警告：此操作将永久禁用并删除 Swap 文件！"
    read -p "$(echo -e "${COLOR_YELLOW}您确定要继续吗? [y/N]: ${COLOR_NC}")" confirm
    if [[ ! "${confirm}" =~ ^[yY]$ ]]; then
        msg "BLUE" "操作已由用户取消。"
        return
    fi

    msg "YELLOW" "正在禁用并从 /etc/fstab 中移除配置..."
    swapoff "${SWAP_FILE_PATH}" 2>/dev/null
    sed -i.bak "\#${SWAP_FILE_PATH}#d" /etc/fstab

    msg "YELLOW" "正在删除 Swap 物理文件..."
    rm -f "${SWAP_FILE_PATH}"
    
    echo ""
    msg "GREEN" "✓ Swap 文件已成功移除！原 /etc/fstab 已备份为 /etc/fstab.bak"
}

main_menu() {
    while true; do
        clear
        msg "BLUE" "##################################################"
        msg "BLUE" "#         虚拟内存管理脚本 (v1.3)          #"
        msg "BLUE" "##################################################"
        show_status
        echo "请选择操作:"
        echo -e "  ${COLOR_YELLOW}--- ZRAM (内存压缩, 速度快, 推荐) ---${COLOR_NC}"
        echo "  1) 安装并配置 ZRAM"
        echo "  2) 移除 ZRAM"
        echo -e "  ${COLOR_YELLOW}--- Swap 文件 (基于硬盘, 速度慢) ---${COLOR_NC}"
        echo "  3) 添加 Swap 文件"
        echo "  4) 移除 Swap 文件"
        echo "  ------------------------------------------------"
        echo "  5) 退出脚本"
        read -p "请输入选项 [1-5]: " choice

        case "$choice" in
            1) configure_zram ;;
            2) remove_zram ;;
            3) create_swap_file ;;
            4) remove_swap_file ;;
            5) msg "BLUE" "感谢使用，脚本已退出。"; exit 0 ;;
            *) msg "RED" "无效的选项 '$choice'，请重新输入。" ;;
        esac
        echo ""
        read -n 1 -s -r -p "按任意键返回主菜单..."
    done
}

initial_checks
main_menu
