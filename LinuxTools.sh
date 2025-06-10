#!/bin/bash

#
# ██╗  ██╗██╗███╗   ██╗██╗   ██╗██╗  ██╗ ██████╗  ██████╗  ██████╗
# ██║  ██║██║████╗  ██║██║   ██║╚██╗██╔╝██╔═══██╗██╔═══██╗██╔═══██╗
# ███████║██║██╔██╗ ██║██║   ██║ ╚███╔╝ ██║   ██║██║   ██║██║   ██║
# ██╔══██║██║██║╚██╗██║██║   ██║ ██╔██╗ ██║   ██║██║   ██║██║   ██║
# ██║  ██║██║██║ ╚████║╚██████╔╝██╔╝ ██╗╚██████╔╝╚██████╔╝╚██████╔╝
# ╚═╝  ╚═╝╚═╝╚═╝  ╚═══╝ ╚═════╝ ╚═╝  ╚═╝ ╚═════╝  ╚═════╝  ╚═════╝
#
# +--------------------------------------------------------------------+
# | Script Name:    Linux Toolbox (v2.4)                             |
# | Author:         xkatld & gemini                    |
# | Description:    一个专业、健壮且用户友好的多功能Linux管理脚本。  |
# | Usage:          sudo bash /path/to/LinuxTools.sh                 |
# +--------------------------------------------------------------------+

#-----------------------------------------------------------------------
# 脚本核心行为设定 (Script Core Behavior)
#-----------------------------------------------------------------------
set -o errexit  # 当命令以非零状态退出时，立即终止脚本。
set -o nounset  # 尝试使用未声明的变量时，视为错误并退出。
set -o pipefail # 管道中的任何一个命令失败，则整个管道的退出码为非零。

#-----------------------------------------------------------------------
# 脚本配置：菜单与远程脚本源 (Configuration Area)
#-----------------------------------------------------------------------
# 使用关联数组 (associative array) 定义菜单，易于扩展和维护。
# 格式: [菜单编号]="菜单描述;脚本的URL"
declare -A SCRIPTS
SCRIPTS=(
    ["1"]="LXD 安装与镜像管理;https://raw.githubusercontent.com/xkatld/LinuxTools/refs/heads/main/shell/lxd-helper.sh"
    ["2"]="SWAP 虚拟内存管理;https://raw.githubusercontent.com/xkatld/linuxtools/main/LinuxSWAP.sh"
    ["3"]="SSH 端口与配置管理;https://raw.githubusercontent.com/xkatld/LinuxTools/main/LinuxSSH.sh"
    ["4"]="Docker 安装 (国内镜像);https://linuxmirrors.cn/docker.sh"
    ["5"]="更换系统软件源 (国内镜像);https://linuxmirrors.cn/main.sh"
    ["6"]="网络配置备份;https://raw.githubusercontent.com/xkatld/LinuxTools/main/network-backup.sh"
    ["7"]="安装并开启 BBRv3;https://raw.githubusercontent.com/xkatld/LinuxTools/main/bbrscript.sh"
)

#-----------------------------------------------------------------------
# 颜色与样式定义 (Color and Style Definitions)
#-----------------------------------------------------------------------
# 使用 readonly 确保这些变量在脚本执行期间不会被意外修改。
readonly COLOR_BLUE='\033[0;34m'
readonly COLOR_GREEN='\033[0;32m'
readonly COLOR_RED='\033[0;31m'
readonly COLOR_YELLOW='\033[1;33m'
readonly COLOR_CYAN='\033[0;36m'
readonly COLOR_NC='\033[0m' # No Color / Reset

#-----------------------------------------------------------------------
# 通用功能函数 (Utility Functions)
#-----------------------------------------------------------------------

# 打印日志信息。
# 用法: msg_info "正在处理..."
msg_info() { echo -e "${COLOR_CYAN}[*] $1${COLOR_NC}"; }
msg_ok() { echo -e "${COLOR_GREEN}[+] $1${COLOR_NC}"; }
msg_error() { echo -e "${COLOR_RED}[!] 错误: $1${COLOR_NC}" >&2; }
msg_warn() { echo -e "${COLOR_YELLOW}[-] 警告: $1${COLOR_NC}"; }

# 检查脚本是否以 root 权限运行，这是许多系统管理任务的前提。
check_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        msg_error "此脚本的大部分功能需要以 root 权限运行。请使用 'sudo'。"
        exit 1
    fi
}

# 检查脚本运行所必需的外部命令。
check_dependencies() {
    local dependencies=("curl" "mktemp" "sort")
    msg_info "正在检查核心依赖: ${dependencies[*]}..."
    for cmd in "${dependencies[@]}"; do
        if ! command -v "$cmd" &>/dev/null; then
            msg_error "依赖命令 '$cmd' 未找到。请先安装它。"
            exit 1
        fi
    done
}

# 从给定的 URL 下载脚本内容。
# 使用 curl 的 -fsS 选项组合：-f (fail fast), -s (silent), -S (show error)。
download_script() {
    local url="$1"
    curl -fsS "$url"
}

# 核心功能：下载并执行一个远程脚本。
execute_remote_script() {
    local url="$1"
    local description="$2"

    msg_info "准备执行脚本: ${description}"

    # 使用 mktemp 创建一个安全的、唯一的临时文件来存放下载的脚本。
    local temp_script
    temp_script=$(mktemp)

    # 设置一个陷阱(trap)，确保无论脚本如何退出（正常结束、Ctrl+C、错误），
    # 临时文件总能被自动删除，避免留下垃圾文件。
    # 使用双引号是关键，它让 $temp_script 在 trap 定义时立即被其值替换。
    trap "rm -f '$temp_script'" EXIT HUP INT QUIT TERM

    msg_info "正在从 $url 下载脚本..."
    local script_content
    script_content=$(download_script "$url")

    if [[ -z "$script_content" ]]; then
        msg_error "从 $url 下载脚本失败或脚本内容为空。"
        return 1
    fi
    msg_ok "脚本下载成功，已存入临时文件。"

    echo "$script_content" > "$temp_script"
    chmod +x "$temp_script"

    msg_warn "您即将从互联网执行一个脚本。请确保您信任来源: ${url}"
    read -p "是否继续执行? (y/N): " confirm
    if [[ ! "$confirm" =~ ^[yY]$ ]]; then
        msg_info "操作已由用户取消。"
        return 0
    fi

    msg_info "开始执行脚本..."
    echo -e "-------------------- 开始执行子脚本 --------------------\n"

    bash "$temp_script"
    local exit_code=$? # 保存子脚本的退出码

    echo -e "\n-------------------- 子脚本执行完毕 --------------------"

    if [[ $exit_code -eq 0 ]]; then
        msg_ok "脚本 '${description}' 执行成功。"
    else
        msg_error "脚本 '${description}' 执行时返回了错误码: $exit_code"
    fi
}

# 显示主菜单。此函数专注于 UI 的渲染。
show_main_menu() {
    clear
    local title=" Linux 工具箱 "
    local author=" by xkatld "
    local width=52 # 定义菜单总宽度

    #-- 动态计算标题栏的填充，使其完美居中 --#
    local title_len=${#title}
    local author_len=${#author}
    local separator_len=$((width - title_len - author_len))
    local sep1_len=$((separator_len / 2))
    local sep2_len=$((separator_len - sep1_len))
    # 使用 printf 和 seq 高效生成重复的字符
    local sep1 && sep1=$(printf '─%.0s' $(seq 1 $sep1_len))
    local sep2 && sep2=$(printf '─%.0s' $(seq 1 $sep2_len))

    #-- 绘制UI界面 --#
    # 1. 顶部边框与标题
    printf "${COLOR_BLUE}┌${sep1}${COLOR_YELLOW}${title}${COLOR_CYAN}${author}${COLOR_BLUE}${sep2}┐${COLOR_NC}\n"

    # 2. 循环打印菜单项
    for key in $(echo "${!SCRIPTS[@]}" | tr ' ' '\n' | sort -n); do
        local item="${SCRIPTS[$key]}"
        local description="${item%%;*}"
        local menu_line=$(printf "  %s) %s" "$key" "$description")
        # 使用 printf 的 "%-*s" 格式化，实现带颜色的、自动填充的左对齐文本
        printf "${COLOR_BLUE}│${COLOR_GREEN}%-*s${COLOR_BLUE}│${COLOR_NC}\n" "$((width - 2))" "$menu_line"
    done

    # 3. 分隔线
    printf "${COLOR_BLUE}├" && printf '─%.0s' $(seq 1 $((width-2))) && printf "┤${COLOR_NC}\n"

    # 4. 退出选项
    local exit_line=$(printf "  %s) %s" "0" "退出脚本")
    printf "${COLOR_BLUE}│${COLOR_RED}%-*s${COLOR_BLUE}│${COLOR_NC}\n" "$((width - 2))" "$exit_line"

    # 5. 底部边框
    printf "${COLOR_BLUE}└" && printf '─%.0s' $(seq 1 $((width-2))) && printf "┘${COLOR_NC}\n"
    
    # 6. 用户输入提示
    read -p "  请选择您的操作: " choice
}

#-----------------------------------------------------------------------
# 主程序入口 (Main Program Logic)
#-----------------------------------------------------------------------
main() {
    # 脚本启动时的初始化检查
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
            # 退出脚本
            msg_info "感谢使用，再见！"
            exit 0
        else
            # 处理无效输入
            msg_error "无效的选择 '$choice'，请重新输入。"
        fi

        # 等待用户按键，防止信息一闪而过
        echo
        read -n 1 -s -r -p "按任意键返回主菜单..."
    done
}

# --- 启动脚本 ---
main
