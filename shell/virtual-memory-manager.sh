#!/bin/bash
#
# ====================================================================
# Script Name:    虚拟内存管理脚本 (Virtual Memory Manager) v1.1
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
    local dependencies=("free" "grep" "sed" "awk" "systemctl")
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
    # swapon --summary 可能会在没有 swap 时报错, 用 || true 忽略错误
    swapon --summary || msg "YELLOW" "  -> 当前没有活动的 Swap 设备。"
    echo ""
    echo "内存使用情况:"
    free -h
    echo "------------------------------------"
}


# --- ZRAM 管理功能 ---

# 功能: 配置并启用 ZRAM
configure_zram() {
    msg "BLUE" "--- [ZRAM] 安装并配置 ZRAM ---"
    if ! command -v apt-get &> /dev/null; then
        msg "RED" "错误: ZRAM 的自动安装目前仅支持基于 apt 的系统 (Debian/Ubuntu)。"
        return 1
    fi

    msg "YELLOW" "正在安装 zram-tools..."
    # 使用DEBIAN_FRONTEND=noninteractive避免安装过程中的交互提示
    DEBIAN_FRONTEND=noninteractive apt-get update -y && apt-get install -y zram-tools

    local zram_size
    while true; do
        read -p "请输入 ZRAM 大小 (MB, 推荐值为物理内存的50%-100%): " zram_size
        if [[ "$zram_size" =~ ^[1-9][0-9]*$ ]]; then
            break
        else
            msg "RED" "输入无效，请输入一个正整数。"
        fi
    done

    msg "YELLOW" "正在配置 ZRAM 服务..."
    # 不同发行版的zram-tools包，其服务和配置文件名可能不同
    # 此处选择兼容性较好的 zram-config 方式
    local zram_config_file="/etc/default/zram-config"
    local zram_service_name="zram-config.service"
    
    # 写入配置
    echo -e "ALGO=zstd\nSIZE=${zram_size}" > "$zram_config_file"

    # 重启服务以应用配置
    msg "YELLOW" "正在重启 ZRAM 服务 ($zram_service_name)..."
    systemctl restart "$zram_service_name"

    echo ""
    msg "GREEN" "✓ ZRAM 已成功配置并启用！"
}

# 功能: 移除 ZRAM (已优化)
remove_zram() {
    msg "BLUE" "--- [ZRAM] 移除 ZRAM ---"
    
    # 定义一个包含所有可能的 ZRAM 服务名称的数组
    local possible_services=("zram-config.service" "zramswap.service")
    local active_service=""

    # 智能检测哪个服务当前是活动的
    for service in "${possible_services[@]}"; do
        if systemctl is-active --quiet "$service"; then
            active_service="$service"
            msg "GREEN" "检测到活动的 ZRAM 服务: $active_service"
            break
        fi
    done

    # 检查 zram-tools 包是否存在
    local zram_tools_installed=false
    if dpkg -s "zram-tools" &>/dev/null; then
        zram_tools_installed=true
    fi

    if [[ -z "$active_service" && "$zram_tools_installed" = false ]]; then
        msg "RED" "错误: 未检测到活动的 ZRAM 服务或 zram-tools 包，无需移除。"
        return 1
    fi

    msg "RED" "警告：此操作将停止 ZRAM 服务并卸载 zram-tools 包！"
    read -p "$(msg "YELLOW" "您确定要继续吗? [y/N]: ")" confirm
    if [[ ! "${confirm}" =~ ^[yY]$ ]]; then
        msg "BLUE" "操作已由用户取消。"
        return
    fi

    # 如果检测到了活动的服务，则停止它
    if [[ -n "$active_service" ]]; then
        msg "YELLOW" "正在停止并禁用服务: $active_service..."
        systemctl stop "$active_service"
        systemctl disable "$active_service"
    else
        msg "YELLOW" "未找到活动的 ZRAM 服务，跳过停止服务步骤。"
    fi

    # 如果 zram-tools 包已安装，则卸载它
    if [[ "$zram_tools_installed" = true ]]; then
        msg "YELLOW" "正在卸载 zram-tools 并清理配置..."
        apt-get purge -y zram-tools
    fi
    
    echo ""
    msg "GREEN" "✓ ZRAM 已成功移除！"
}


# --- Swap 文件管理功能 (无变动) ---
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
        msg "BLUE" "#         虚拟内存管理脚本 (v1.1)          #"
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
