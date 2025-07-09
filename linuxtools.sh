#!/bin/bash
#
# +--------------------------------------------------------------------+
# | Script Name:    Linux Toolbox (v2.6 Robust)                        |
# | Author:         xkatld & gemini                                    |
# | Description:    一个多功能、用户友好的Linux管理脚本工具箱。        |
# | Usage:          sudo bash /path/to/LinuxTools.sh                 |
# +--------------------------------------------------------------------+

# --- 安全设置 ---
# errexit: 如果命令返回非零退出状态，则立即退出。
# nounset: 如果引用了未设置的变量，则视为错误。
# pipefail: 如果管道中的任何命令失败，则整个管道的退出状态为非零。
set -o errexit
set -o nounset
set -o pipefail

# --- 脚本配置 ---
# 使用关联数组存储脚本描述和URL，方便扩展
declare -A SCRIPTS
SCRIPTS=(
    ["1"]="LXD安装与镜像管理;https://git.fsytool.top/xkatld/linuxtools/raw/branch/main/shell/lxd-helper.sh"
    ["2"]="虚拟内存综合管理;https://git.fsytool.top/xkatld/linuxtools/raw/branch/main/shell/virtual-memory-manager.sh"
    ["3"]="linuxmirrors综合脚本;https://git.fsytool.top/xkatld/linuxtools/raw/branch/main/shell/linuxmirrors.sh"
    ["4"]="SSH综合管理;https://git.fsytool.top/xkatld/linuxtools/raw/branch/main/shell/ssh-manager.sh"
    ["5"]="系统优化综合脚本;https://git.fsytool.top/xkatld/linuxtools/raw/branch/main/shell/SysOptimize.sh"
    ["6"]="PVE安装与镜像管理;https://git.fsytool.top/xkatld/linuxtools/raw/branch/main/shell/install-pve.sh"
    ["7"]="Linux系统升级脚本;https://git.fsytool.top/xkatld/linuxtools/raw/branch/main/shell/apt-update.sh"
    ["8"]="硬盘分区管理;https://git.fsytool.top/xkatld/linuxtools/raw/branch/main/shell/disk-manager.sh"
)

# --- 颜色定义 ---
readonly COLOR_GREEN='\033[0;32m'
readonly COLOR_RED='\033[0;31m'
readonly COLOR_YELLOW='\033[1;33m'
readonly COLOR_CYAN='\033[0;36m'
readonly COLOR_NC='\033[0m' # No Color

# --- 消息函数 ---
msg_info() { echo -e "${COLOR_CYAN}[*] $1${COLOR_NC}"; }
msg_ok() { echo -e "${COLOR_GREEN}[+] $1${COLOR_NC}"; }
msg_error() { echo -e "${COLOR_RED}[!] 错误: $1${COLOR_NC}" >&2; }
msg_warn() { echo -e "${COLOR_YELLOW}[-] 警告: $1${COLOR_NC}"; }

# --- 核心功能函数 ---

# 检查是否以 root 权限运行
check_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        msg_error "此脚本的大部分功能需要 root 权限，请使用 'sudo' 运行。"
        exit 1
    fi
}

# 检查核心依赖
check_dependencies() {
    local dependencies=("curl" "mktemp" "sort")
    msg_info "正在检查核心依赖: ${dependencies[*]}..."
    for cmd in "${dependencies[@]}"; do
        if ! command -v "$cmd" &>/dev/null; then
            msg_error "依赖命令 '$cmd' 未找到，请先安装它。"
            exit 1
        fi
    done
    # 可选依赖检查：检查 clear 命令，如果不存在则发出警告
    if ! command -v "clear" &>/dev/null; then
        msg_warn "'clear' 命令未找到。将使用备用方式清屏，不影响功能。"
    fi
}

# 兼容性清屏函数
clear_screen() {
    # 优先使用 clear 命令，如果不存在则使用 ANSI 转义序列清屏
    if command -v "clear" &>/dev/null; then
        clear
    else
        # \033[2J 清除整个屏幕
        # \033[H  将光标移动到左上角 (第一行, 第一列)
        printf '\033[2J\033[H'
    fi
}

# 下载并执行远程脚本
execute_remote_script() {
    local url="$1"
    local description="$2"
    msg_info "准备执行: ${description}"
    
    # 创建临时文件来存放下载的脚本
    local temp_script
    temp_script=$(mktemp)
    # 设置 trap，确保脚本退出时（无论正常或异常）都能删除临时文件
    trap "rm -f '$temp_script'" EXIT HUP INT QUIT TERM
    
    msg_info "正在从 $url 下载脚本..."
    # 使用 curl 下载脚本内容，-fsS 选项可以在出错时静默，但仍显示网络错误
    local script_content
    script_content=$(curl -fsS "$url")
    
    # 检查脚本是否下载成功或内容是否为空
    if [[ -z "$script_content" ]]; then
        msg_error "从 $url 下载脚本失败或脚本内容为空。"
        return 1
    fi
    msg_ok "脚本下载成功。"
    
    echo "$script_content" > "$temp_script"
    chmod +x "$temp_script"
    
    msg_warn "您即将从网络执行一个脚本，请确认您信任来源: ${url}"
    read -p "是否继续执行? (y/N): " confirm
    # 使用正则表达式匹配，只有输入 'y' 或 'Y' 才继续
    if [[ ! "$confirm" =~ ^[yY]$ ]]; then
        msg_info "操作已由用户取消。"
        return 0
    fi
    
    msg_info "开始执行子脚本..."
    echo -e "-------------------- 开始执行子脚本 --------------------\n"
    # 使用 bash 执行脚本，而不是 source，以避免污染当前脚本的环境
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
    clear_screen # 使用我们新的、更具兼容性的清屏函数
    echo -e "${COLOR_GREEN}========================================="
    echo -e "        Linux 工具箱 (作者: xkatld)        "
    echo -e "=========================================${COLOR_NC}"
    
    # 动态生成菜单项，并按数字排序
    # 使用 printf 和 sort -n 来确保数字顺序正确（例如 1, 2, ..., 10）
    for key in $(printf '%s\n' "${!SCRIPTS[@]}" | sort -n); do
        local item="${SCRIPTS[$key]}"
        local description="${item%%;*}"
        printf "  %-2s) %s\n" "$key" "$description"
    done
    
    echo "  ---------------------------------------"
    echo -e "  ${COLOR_RED}0) 退出脚本${COLOR_NC}"
    echo -e "${COLOR_GREEN}=========================================${COLOR_NC}"
    read -p "请输入您的选择: " choice
}

# 主函数
main() {
    check_root
    check_dependencies
    
    while true; do
        show_main_menu
        # 检查用户的输入是否存在于 SCRIPTS 数组的键中
        if [[ -n "${SCRIPTS[$choice]:-}" ]]; then
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
        
        echo # 输出一个空行以增加间距
        # 暂停脚本，等待用户按任意键继续，-s不回显输入，-r禁止反斜杠转义
        read -n 1 -s -r -p "按任意键返回主菜单..."
    done
}

# --- 脚本执行入口 ---
main "$@"
