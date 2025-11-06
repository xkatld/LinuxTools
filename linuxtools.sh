#!/bin/bash

set -euo pipefail

readonly GITHUB_RAW_URL="https://raw.githubusercontent.com/xkatld/LinuxTools/refs/heads/main/shell"

declare -A SCRIPTS=(
    ["1"]="虚拟内存综合管理;${GITHUB_RAW_URL}/virtual-memory-manager.sh"
    ["2"]="linuxmirrors综合脚本;${GITHUB_RAW_URL}/linuxmirrors.sh"
    ["3"]="SSH综合管理;${GITHUB_RAW_URL}/ssh-manager.sh"
    ["4"]="PVE安装与镜像管理;${GITHUB_RAW_URL}/install-pve.sh"
    ["5"]="Linux系统升级脚本;${GITHUB_RAW_URL}/apt-update.sh"
    ["6"]="硬盘分区管理;${GITHUB_RAW_URL}/disk-manager.sh"
)

msg_info() { echo "[INFO] $1"; }
msg_ok() { echo "[OK] $1"; }
msg_error() { echo "[ERROR] $1" >&2; }
msg_warn() { echo "[WARN] $1"; }

check_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        msg_error "此脚本需要 root 权限，请使用 'sudo' 运行。"
        exit 1
    fi
}

check_dependencies() {
    local deps=("curl" "mktemp" "sort")
    msg_info "正在检查核心依赖..."
    for cmd in "${deps[@]}"; do
        if ! command -v "$cmd" &>/dev/null; then
            msg_error "依赖命令 '$cmd' 未找到，请先安装。"
            exit 1
        fi
    done
    if ! command -v "clear" &>/dev/null; then
        msg_warn "'clear' 命令未找到，将使用备用清屏方式。"
    fi
}

clear_screen() {
    clear 2>/dev/null || printf '\033[2J\033[H'
}

execute_remote_script() {
    local url="$1"
    local description="$2"
    local temp_script
    
    msg_info "准备执行: ${description}"
    temp_script=$(mktemp)
    trap "rm -f '$temp_script'" RETURN EXIT
    
    msg_info "正在下载脚本..."
    if ! curl -fsSL "$url" -o "$temp_script" 2>/dev/null; then
        msg_error "脚本下载失败，请检查网络连接。"
        return 1
    fi
    
    if [[ ! -s "$temp_script" ]]; then
        msg_error "下载的脚本为空。"
        return 1
    fi
    msg_ok "脚本下载成功。"
    
    chmod +x "$temp_script"
    
    msg_warn "即将执行网络脚本: ${url}"
    read -p "是否继续? (Y/n): " -r confirm
    confirm=${confirm:-Y}
    if [[ "$confirm" =~ ^[nN]$ ]]; then
        msg_info "操作已取消。"
        return 0
    fi
    
    echo
    bash "$temp_script"
    local exit_code=$?
    echo
    
    if [[ $exit_code -eq 0 ]]; then
        msg_ok "'${description}' 执行成功。"
    else
        msg_error "'${description}' 执行失败 (退出码: $exit_code)"
    fi
}

show_main_menu() {
    clear_screen
    echo "========================================="
    echo "        Linux 工具箱 (作者: xkatld)"
    echo "========================================="
    
    for key in $(printf '%s\n' "${!SCRIPTS[@]}" | sort -n); do
        local item="${SCRIPTS[$key]}"
        local description="${item%%;*}"
        printf "  %-2s) %s\n" "$key" "$description"
    done
    
    echo "  ---------------------------------------"
    echo "  0) 退出脚本"
    echo "========================================="
    read -p "请输入您的选择: " -r choice
}

main() {
    check_root
    check_dependencies
    
    while true; do
        show_main_menu
        
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
        
        echo
        read -n 1 -s -r -p "按任意键返回主菜单..."
    done
}

main "$@"
