#!/bin/bash

set -o errexit
set -o nounset
set -o pipefail

readonly COLOR_GREEN='\033[0;32m'
readonly COLOR_RED='\033[0;31m'
readonly COLOR_YELLOW='\033[1;33m'
readonly COLOR_CYAN='\033[0;36m'
readonly COLOR_NC='\033[0m'

msg_info() { echo -e "${COLOR_CYAN}[*] $1${COLOR_NC}"; }
msg_ok() { echo -e "${COLOR_GREEN}[+] $1${COLOR_NC}"; }
msg_error() { echo -e "${COLOR_RED}[!] 错误: $1${COLOR_NC}" >&2; }
msg_warn() { echo -e "${COLOR_YELLOW}[-] 警告: $1${COLOR_NC}"; }

check_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        msg_error "此脚本需要 root 权限，请使用 'sudo' 运行。"
        exit 1
    fi
}

check_dependencies() {
    if ! command -v curl &>/dev/null; then
        msg_error "核心命令 'curl' 未找到，请先安装它。"
        exit 1
    fi
}

run_remote_script() {
    local url="$1"
    local description="$2"
    local args="${3:-}"

    msg_warn "您即将从网络执行脚本: ${description}"
    msg_warn "来源 URL: ${url}"
    if [[ -n "$args" ]]; then
        msg_warn "附带参数: ${args}"
    fi

    read -p "是否确认并继续执行? (y/N): " confirm
    if [[ ! "$confirm" =~ ^[yY]$ ]]; then
        msg_info "操作已由用户取消。"
        return 0
    fi

    msg_info "正在执行命令: bash <(curl -sSL ${url}) ${args}"
    echo -e "-------------------- 开始执行子脚本 --------------------\n"
    bash <(curl -sSL "$url") $args
    local exit_code=$?
    echo -e "\n-------------------- 子脚本执行完毕 --------------------"
    
    if [[ $exit_code -eq 0 ]]; then
        msg_ok "'${description}' 执行成功。"
    else
        msg_error "'${description}' 执行时返回了错误码: $exit_code"
    fi
}

show_menu() {
    clear
    echo -e "${COLOR_GREEN}========================================="
    echo -e "         LinuxMirrors 脚本启动器         "
    echo -e "=========================================${COLOR_NC}"
    echo "  1) 更换系统软件源 (国内服务器)"
    echo "  2) 更换系统软件源 (海外服务器)"
    echo "  3) 安装 Docker (使用国内镜像)"
    echo "  ---------------------------------------"
    echo -e "  ${COLOR_RED}0) 退出脚本${COLOR_NC}"
    echo -e "${COLOR_GREEN}=========================================${COLOR_NC}"
}

main() {
    check_root
    check_dependencies
    
    while true; do
        show_menu
        read -p "请输入您的选择: " choice
        
        case "$choice" in
            "1")
                run_remote_script "https://linuxmirrors.cn/main.sh" "更换系统软件源 (国内)"
                break
                ;;
            "2")
                run_remote_script "https://linuxmirrors.cn/main.sh" "更换系统软件源 (海外)" "--abroad"
                break
                ;;
            "3")
                run_remote_script "https://linuxmirrors.cn/docker.sh" "安装 Docker (国内镜像)"
                break
                ;;
            "0")
                msg_info "感谢使用，再见！"
                exit 0
                ;;
            *)
                msg_error "无效的选择 '$choice'，请重新输入。"
                sleep 2
                ;;
        esac
    done
}

main
