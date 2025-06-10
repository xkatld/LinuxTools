#!/bin/bash
#
# +--------------------------------------------------------------------+
# | Script Name:    Linux Toolbox (v2.5 Refined)                       |
# | Author:         xkatld & gemini                                    |
# | Description:    一个多功能、用户友好的Linux管理脚本工具箱。        |
# | Usage:          sudo bash /path/to/LinuxTools.sh                 |
# +--------------------------------------------------------------------+

# --- 脚本核心设定 ---
# 这三个命令让脚本变得更安全、更可预测：
# -e: 任何命令执行失败，脚本立即退出。
# -u: 尝试使用未定义的变量，脚本会报错并退出。
# -o pipefail: 管道中的任何一个命令失败，整个管道都算失败。
set -o errexit
set -o nounset
set -o pipefail

# --- 功能菜单配置 ---
# 使用关联数组定义菜单，方便未来增加或修改功能。
# 格式: ["菜单编号"]="菜单描述;脚本URL"
declare -A SCRIPTS
SCRIPTS=(
    ["1"]="LXD 安装与镜像管理;https://raw.githubusercontent.com/xkatld/LinuxTools/refs/heads/main/shell/lxd-helper.sh"
    ["2"]="虚拟内存综合管理 (ZRAM & Swap);https://raw.githubusercontent.com/xkatld/LinuxTools/refs/heads/main/shell/virtual-memory-manager.sh"
    ["3"]="SSH 端口与配置管理;https://raw.githubusercontent.com/xkatld/LinuxTools/main/LinuxSSH.sh"
    ["4"]="Docker 安装 (国内镜像);https://linuxmirrors.cn/docker.sh"
    ["5"]="更换系统软件源 (国内镜像);https://linuxmirrors.cn/main.sh"
    ["6"]="网络配置备份;https://raw.githubusercontent.com/xkatld/LinuxTools/main/network-backup.sh"
    ["7"]="安装并开启 BBRv3;https://raw.githubusercontent.com/xkatld/LinuxTools/main/bbrscript.sh"
)

# --- 颜色定义 ---
readonly COLOR_GREEN='\033[0;32m'
readonly COLOR_RED='\033[0;31m'
readonly COLOR_YELLOW='\033[1;33m'
readonly COLOR_CYAN='\033[0;36m'
readonly COLOR_NC='\033[0m' # 重置颜色

# --- 通用函数 ---

# 打印不同类型的消息
msg_info() { echo -e "${COLOR_CYAN}[*] $1${COLOR_NC}"; }
msg_ok() { echo -e "${COLOR_GREEN}[+] $1${COLOR_NC}"; }
msg_error() { echo -e "${COLOR_RED}[!] 错误: $1${COLOR_NC}" >&2; }
msg_warn() { echo -e "${COLOR_YELLOW}[-] 警告: $1${COLOR_NC}"; }

# 检查脚本是否以 root 权限运行
check_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        msg_error "此脚本的大部分功能需要 root 权限，请使用 'sudo' 运行。"
        exit 1
    fi
}

# 检查脚本运行必需的外部命令
check_dependencies() {
    local dependencies=("curl" "mktemp" "sort")
    msg_info "正在检查核心依赖: ${dependencies[*]}..."
    for cmd in "${dependencies[@]}"; do
        if ! command -v "$cmd" &>/dev/null; then
            msg_error "依赖命令 '$cmd' 未找到，请先安装它。"
            exit 1
        fi
    done
}

# 下载并执行远程脚本的核心功能
execute_remote_script() {
    local url="$1"
    local description="$2"

    msg_info "准备执行: ${description}"

    # 创建一个安全的临时文件来存放下载的脚本
    local temp_script
    temp_script=$(mktemp)

    # 设置陷阱 (trap)，确保无论脚本如何退出，临时文件都会被自动删除
    trap "rm -f '$temp_script'" EXIT HUP INT QUIT TERM

    msg_info "正在从 $url 下载脚本..."
    local script_content
    # 使用 curl 的 -fsS 选项：静默模式，但在失败时显示错误
    script_content=$(curl -fsS "$url")

    if [[ -z "$script_content" ]]; then
        msg_error "从 $url 下载脚本失败或脚本内容为空。"
        return 1
    fi
    msg_ok "脚本下载成功。"

    echo "$script_content" > "$temp_script"
    chmod +x "$temp_script"

    msg_warn "您即将从网络执行一个脚本，请确认您信任来源: ${url}"
    read -p "是否继续执行? (y/N): " confirm
    if [[ ! "$confirm" =~ ^[yY]$ ]]; then
        msg_info "操作已由用户取消。"
        return 0
    fi

    msg_info "开始执行子脚本..."
    echo -e "-------------------- 开始执行子脚本 --------------------\n"

    bash "$temp_script"
    local exit_code=$? # 保存子脚本的退出码

    echo -e "\n-------------------- 子脚本执行完毕 --------------------"

    if [[ $exit_code -eq 0 ]]; then
        msg_ok "'${description}' 执行成功。"
    else
        msg_error "'${description}' 执行时返回了错误码: $exit_code"
    fi
}

# 显示主菜单
show_main_menu() {
    clear
    echo -e "${COLOR_GREEN}========================================="
    echo -e "        Linux 工具箱 (作者: xkatld)        "
    echo -e "=========================================${COLOR_NC}"
    
    # 循环打印菜单项
    for key in $(echo "${!SCRIPTS[@]}" | tr ' ' '\n' | sort -n); do
        local item="${SCRIPTS[$key]}"
        local description="${item%%;*}"
        printf "  %-2s) %s\n" "$key" "$description"
    done

    echo "  ---------------------------------------"
    echo -e "  ${COLOR_RED}0) 退出脚本${COLOR_NC}"
    echo -e "${COLOR_GREEN}=========================================${COLOR_NC}"
    
    read -p "请输入您的选择: " choice
}

# --- 主程序入口 ---
main() {
    check_root
    check_dependencies

    # 无限循环，直到用户选择退出
    while true; do
        show_main_menu

        if [[ -n "${SCRIPTS[$choice]:-}" ]]; then
            # 如果选择有效，提取描述和URL并执行
            local item="${SCRIPTS[$choice]}"
            local description="${item%%;*}"
            local url="${item##*;}"
            execute_remote_script "$url" "$description"
        elif [[ "$choice" == "0" ]]; then
            msg_info "感谢使用，再见！"
            exit 0
        else
            msg_error "无效的选择 '$choice'，请重新输入。"
        fi

        # 等待用户按键，防止信息一闪而过
        echo
        read -n 1 -s -r -p "按任意键返回主菜单..."
    done
}

# --- 启动脚本 ---
main
