#!/bin/bash

# ==============================================================================
# Script Name:    Linux Toolbox (Enhanced)
# Description:    A robust and user-friendly menu to run various Linux admin scripts.
# Author:         xkatld & gemini (as 脚本大师)
# Version:        2.0
# Usage:          ./toolbox.sh
# ==============================================================================

# --- 安全设置：任何命令失败立即退出，使用未定义变量报错 ---
set -o errexit
set -o nounset
set -o pipefail

# --- 脚本配置区 (可轻松扩展) ---
# 使用关联数组存储菜单项，格式：[ID]="菜单描述;脚本URL"
declare -A SCRIPTS
SCRIPTS=(
    ["1"]="LXD 安装与管理;https://raw.githubusercontent.com/xkatld/linuxtools/main/LXDInstall.sh"
    ["2"]="SWAP 虚拟内存管理;https://raw.githubusercontent.com/xkatld/linuxtools/main/LinuxSWAP.sh"
    ["3"]="SSH 端口与配置管理;https://raw.githubusercontent.com/xkatld/LinuxTools/main/LinuxSSH.sh"
    ["4"]="Docker 安装 (国内镜像);https://linuxmirrors.cn/docker.sh"
    ["5"]="更换系统软件源 (国内镜像);https://linuxmirrors.cn/main.sh"
    ["6"]="网络配置备份;https://raw.githubusercontent.com/xkatld/LinuxTools/main/network-backup.sh"
    ["7"]="安装并开启 BBRv3;https://raw.githubusercontent.com/xkatld/LinuxTools/main/bbrscript.sh"
)
# 注意：原脚本菜单中的 4 (LXC 操作) 在 lxd-helper.sh 中，已合并到选项 1。此处新增了 Docker 和换源。

# --- 颜色定义 ---
readonly COLOR_BLUE='\033[0;34m'
readonly COLOR_GREEN='\033[0;32m'
readonly COLOR_RED='\033[0;31m'
readonly COLOR_YELLOW='\033[1;33m'
readonly COLOR_NC='\033[0m' # No Color

# --- 通用日志函数 ---
# 信息日志 (蓝色)
msg_info() {
    echo -e "${COLOR_BLUE}[*] $1${COLOR_NC}"
}
# 成功日志 (绿色)
msg_ok() {
    echo -e "${COLOR_GREEN}[+] $1${COLOR_NC}"
}
# 错误日志 (红色)
msg_error() {
    echo -e "${COLOR_RED}[!] 错误: $1${COLOR_NC}" >&2
}
# 警告日志 (黄色)
msg_warn() {
    echo -e "${COLOR_YELLOW}[-] 警告: $1${COLOR_NC}"
}

# --- 核心功能函数 ---

# 检查脚本是否以 root 权限运行
check_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        msg_error "此脚本需要以 root 权限运行。请尝试使用 'sudo ./script_name.sh'。"
        exit 1
    fi
    msg_ok "Root 权限检查通过。"
}

# 检查脚本依赖的外部命令是否存在
check_dependencies() {
    local dependencies=("curl" "mktemp")
    msg_info "正在检查依赖项..."
    for cmd in "${dependencies[@]}"; do
        if ! command -v "$cmd" &>/dev/null; then
            msg_error "依赖命令 '$cmd' 未找到。请先安装它 (例如: 'apt update && apt install $cmd')。"
            exit 1
        fi
    done
    msg_ok "所有依赖项均已安装。"
}

# 从 URL 下载脚本内容
# 参数: $1 -> URL
download_script() {
    local url="$1"
    # 使用 curl 的 -f 选项，在遇到 HTTP 4xx/5xx 错误时会静默失败并返回非零状态码
    curl -fsS "$url"
}

# 执行远程脚本
# 参数: $1 -> URL
# 参数: $2 -> 描述
execute_remote_script() {
    local url="$1"
    local description="$2"
    
    msg_info "准备执行脚本: ${description}"
    
    # 创建安全的临时文件，并设置 trap 以确保在任何情况下（包括Ctrl+C）都能清理
    local temp_script
    temp_script=$(mktemp)
    trap 'rm -f "$temp_script"' EXIT HUP INT QUIT TERM

    msg_info "正在从 $url 下载脚本..."
    local script_content
    script_content=$(download_script "$url")

    if [[ -z "$script_content" ]]; then
        msg_error "从 $url 下载脚本失败或脚本内容为空。"
        # trap 会自动清理，此处直接退出
        return 1
    fi
    msg_ok "脚本下载成功。"

    # 将内容写入临时文件并赋予执行权限
    echo "$script_content" > "$temp_script"
    chmod +x "$temp_script"

    # 执行前的最后警告
    msg_warn "您即将从互联网执行一个脚本。请确保您信任来源: ${url}"
    read -p "是否继续执行? (y/N): " confirm
    # 如果输入不是 y 或 Y，则中止
    if [[ ! "$confirm" =~ ^[yY]$ ]]; then
        msg_info "操作已取消。"
        return 0
    fi

    msg_info "开始执行脚本..."
    echo -e "-------------------- 开始执行子脚本 --------------------\n"
    # 使用 bash 执行
    bash "$temp_script"
    local exit_code=$?
    echo -e "\n-------------------- 子脚本执行完毕 --------------------"

    if [[ $exit_code -eq 0 ]]; then
        msg_ok "脚本 '${description}' 执行成功。"
    else
        msg_error "脚本 '${description}' 执行时返回了错误码: $exit_code"
    fi

    # trap 会在函数退出时自动清理临时文件
}

# 显示主菜单
show_main_menu() {
    clear
    echo -e "${COLOR_BLUE}=========================================${COLOR_NC}"
    echo -e "${COLOR_BLUE}         Linux 工具箱 (作者: xkatld)      ${COLOR_NC}"
    echo -e "${COLOR_BLUE}=========================================${COLOR_NC}"
    
    # 动态生成菜单项
    for key in $(echo "${!SCRIPTS[@]}" | tr ' ' '\n' | sort -n); do
        local item="${SCRIPTS[$key]}"
        local description="${item%%;*}" # 分号前是描述
        printf "  ${COLOR_YELLOW}%s)${COLOR_NC} %s\n" "$key" "$description"
    done

    echo "  ---------------------------------------"
    echo -e "  ${COLOR_YELLOW}0)${COLOR_NC} 退出脚本"
    echo -e "${COLOR_BLUE}=========================================${COLOR_NC}"
    read -p "请输入您的选择: " choice
}

# --- 主程序逻辑 ---
main() {
    check_root
    check_dependencies
    
    while true; do
        show_main_menu
        
        # 检查选择是否存在于我们的脚本数组中
        if [[ -n "${SCRIPTS[$choice]:-}" ]]; then
            local item="${SCRIPTS[$choice]}"
            local description="${item%%;*}"
            local url="${item##*;}" # 分号后是URL
            
            execute_remote_script "$url" "$description"

        elif [[ "$choice" == "0" ]]; then
            msg_info "感谢使用，再见！"
            exit 0
        else
            msg_error "无效的选择 '$choice'，请重新输入。"
        fi
        
        echo
        read -n 1 -s -r -p "按任意键返回主菜单..."
    done
}

# --- 启动脚本 ---
main
