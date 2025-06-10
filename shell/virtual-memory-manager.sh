#!/bin/bash
#
# ====================================================================
# Script Name:    虚拟内存管理脚本 (Virtual Memory Manager) v1.2
# Author:         xkatld & gemini
# Description:    一个集成了 ZRAM 和 传统 Swap 文件管理功能的专业工具，
#                 旨在安全、便捷地优化系统虚拟内存。
# Usage:          sudo bash virtual-memory-manager.sh
# ====================================================================

# --- 脚本核心行为设定 ---
set -o errexit
set -o nounset
set -o pipefail

# --- 可配置变量 ---
readonly SWAP_FILE_PATH="/swapfile"

# --- 样式与颜色定义 ---
readonly COLOR_GREEN='\033[0;32m'
readonly COLOR_YELLOW='\033[1;33m'
readonly COLOR_RED='\033[0;31m'
readonly COLOR_BLUE='\033[0;34m'
readonly COLOR_NC='\033[0m'

# --- 辅助函数 ---

# 功能: 统一的彩色消息打印函数
msg() {
    local color_name="$1"
    local message="$2"
    local color_var="COLOR_${color_name^^}"
    echo -e "${!color_var}${message}${COLOR_NC}"
}

# 功能: 检查并执行前置条件检查
initial_checks() {
    # 1. 权限检查
    if [[ "${EUID}" -ne 0 ]]; then
        msg "RED" "错误：此脚本需要 root 权限才能修改系统设置。"
        exit 1
    fi

    # 2. 虚拟化环境检查
    if [[ -d "/proc/vz" ]]; then
        msg "RED" "错误：不支持 OpenVZ 虚拟化环境，因为它无法修改内核和 Swap。"
        exit 1
    fi

    # 3. 核心依赖检查
    local dependencies=("free" "grep" "sed" "awk" "systemctl" "dpkg")
    for cmd in "${dependencies[@]}"; do
        if ! command -v "$cmd" &> /dev/null; then
            msg "RED" "错误: 缺少核心命令 '$cmd'，请先安装它。"
            exit 1
        fi
    done
}

# --- 状态显示 ---

# 功能: 显示当前的 Swap 和内存状态
show_status() {
    msg "BLUE" "--- 当前系统虚拟内存状态 ---"
    echo "Swap 摘要:"
    swapon --summary || msg "YELLOW" "  -> 当前没有活动的 Swap 设备。"
    echo ""
    echo "内存使用情况:"
    free -h
    echo "------------------------------------"
}

# --- ZRAM 管理功能 (已重构) ---

# 功能: 智能侦测 ZRAM 的服务和配置文件名
# 输出: "配置文件路径 服务名" 或 空字符串
detect_zram_config() {
    if [[ -f /lib/systemd/system/zramswap.service ]]; then
        # 这是新版/常见的 zram-tools 使用的名称 (如 Debian Bookworm)
        echo "/etc/default/zramswap zramswap.service"
    elif [[ -f /lib/systemd/system/zram-config.service ]]; then
        # 这是某些旧版或不同发行版可能使用的名称
        echo "/etc/default/zram-config zram-config.service"
    else
        echo ""
    fi
}

# 功能: 配置并启用 ZRAM
configure_zram() {
    msg "BLUE" "--- [ZRAM] 安装并配置 ZRAM ---"
    if ! command -v apt-get &> /dev/null; then
        msg "RED" "错误: ZRAM 的自动安装目前仅支持基于 apt 的系统 (Debian/Ubuntu)。"
        return 1
    fi

    msg "YELLOW" "正在安装 zram-tools..."
    DEBIAN_FRONTEND=noninteractive apt-get update -y && apt-get install -y zram-tools

    # 调用侦测器来获取正确的配置信息
    local zram_details
    zram_details=$(detect_zram_config)
    if [[ -z "$zram_details" ]]; then
        msg "RED" "错误: 安装 zram-tools 后，未能侦测到任何已知的 ZRAM 服务文件。无法继续配置。"
        return 1
    fi
    # 将侦测结果读取到独立变量中
    local config_file
    local service_name
    read -r config_file service_name <<< "$zram_details"
    msg "GREEN" "侦测到 ZRAM 配置文件: $config_file, 服务名: $service_name"

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
    # 写入 zstd 压缩算法和用户指定的大小
    echo -e "ALGO=zstd\nSIZE=${zram_size}" > "$config_file"

    msg "YELLOW" "正在重启 ZRAM 服务 ($service_name) 以应用配置..."
    systemctl restart "$service_name"

    echo ""
    msg "GREEN" "✓ ZRAM 已成功配置并启用！"
}

# 功能: 移除 ZRAM
remove_zram() {
    msg "BLUE" "--- [ZRAM] 移除 ZRAM ---"
    
    local zram_details
    zram_details=$(detect_zram_config)
    
    if [[ -z "$zram_details" ]] && ! dpkg -s "zram-tools" &>/dev/null; then
        msg "RED" "错误: 未检测到 ZRAM 服务或 zram-tools 包，无需移除。"
        return 1
    fi

    msg "RED" "警告：此操作将停止 ZRAM 服务并卸载 zram-tools 包！"
    read -p "$(msg "YELLOW" "您确定要继续吗? [y/N]: ")" confirm
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
        apt-get purge -y zram-tools
    fi
    
    echo ""
    msg "GREEN" "✓ ZRAM 已成功移除！"
}


# --- Swap 文件管理功能 (无变动) ---
create_swap_file() {
    msg "BLUE" "--- [Swap文件] 添加 Swap 文件 ---"
    # ... (此处代码无变化)
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
    # ... (此处代码无变化)
    if ! grep -q "${SWAP_FILE_PATH}" /etc/fstab && [ ! -f "${SWAP_FILE_PATH}" ]; then
        msg "RED" "错误: 未找到 Swap 文件或其配置，无需移除。"
        return 1
    fi

    msg "RED" "警告：此操作将永久禁用并删除 Swap 文件！"
    read -p "$(msg "YELLOW" "您确定要继续吗? [y/N]: ")" confirm
    if [[ ! "${confirm}" =~ ^[yY]$ ]]; then
        msg "BLUE" "操作已由用户取消。"
        return
    fi

    msg "YELLOW" "正在禁用并从 /etc/fstab 中移除配置..."
    swapoff "${SWAP_FILE_PATH}"
    sed -i.bak "\#${SWAP_FILE_PATH}#d" /etc/fstab

    msg "YELLOW" "正在删除 Swap 物理文件..."
    rm -f "${SWAP_FILE_PATH}"
    
    echo ""
    msg "GREEN" "✓ Swap 文件已成功移除！原 /etc/fstab 已备份为 /etc/fstab.bak"
}


# --- 主菜单 (无变动) ---
main_menu() {
    while true; do
        clear
        msg "BLUE" "##################################################"
        msg "BLUE" "#         虚拟内存管理脚本 (v1.2)          #"
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
            5)
                msg "BLUE" "感谢使用，脚本已退出。"
                exit 0
                ;;
            *)
                msg "RED" "无效的选项 '$choice'，请重新输入。"
                ;;
        esac
        echo ""
        read -n 1 -s -r -p "按任意键返回主菜单..."
    done
}

# --- 脚本入口 ---
initial_checks
main_menu
