#!/bin/bash

set -o errexit
set -o nounset
set -o pipefail

readonly COLOR_GREEN='\033[0;32m'
readonly COLOR_RED='\033[0;31m'
readonly COLOR_YELLOW='\033[1;33m'
readonly COLOR_CYAN='\033[0;36m'
readonly COLOR_NC='\033[0m'

SSH_CONFIG_FILE=""
SSH_SERVICE_NAME=""

msg_info() { echo -e "${COLOR_CYAN}[*] $1${COLOR_NC}"; }
msg_ok() { echo -e "${COLOR_GREEN}[+] $1${COLOR_NC}"; }
msg_error() { echo -e "${COLOR_RED}[!] 错误: $1${COLOR_NC}" >&2; }
msg_warn() { echo -e "${COLOR_YELLOW}[-] 警告: $1${COLOR_NC}"; }

check_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        msg_error "此脚本需要 root 权限来修改 SSH 配置和重启服务。"
        exit 1
    fi
}

detect_ssh_config() {
    local possible_configs=(
        "/etc/ssh/sshd_config"
        "/etc/sshd_config"
        "/etc/openssh/sshd_config"
    )
    for config in "${possible_configs[@]}"; do
        if [[ -f "$config" ]]; then
            SSH_CONFIG_FILE="$config"
            msg_info "检测到 SSH 配置文件: ${SSH_CONFIG_FILE}"
            return 0
        fi
    done
    msg_error "未找到任何标准的 sshd_config 文件。"
    exit 1
}

detect_ssh_service() {
    if command -v systemctl &>/dev/null; then
        for service in sshd ssh; do
            if systemctl list-units --type=service | grep -q "${service}.service"; then
                SSH_SERVICE_NAME="$service"
                msg_info "检测到 SSH 服务: ${SSH_SERVICE_NAME}"
                return 0
            fi
        done
    elif command -v service &>/dev/null; then
        for service in sshd ssh; do
            if [[ -f "/etc/init.d/${service}" ]]; then
                SSH_SERVICE_NAME="$service"
                msg_info "检测到 SSH 服务: ${SSH_SERVICE_NAME}"
                return 0
            fi
        done
    fi
    msg_error "未找到 systemd 或 init.d 的 SSH 服务。"
    exit 1
}

backup_config() {
    local backup_file="${SSH_CONFIG_FILE}.backup_$(date +%Y%m%d_%H%M%S)"
    msg_info "正在备份当前配置到: ${backup_file}"
    cp "$SSH_CONFIG_FILE" "$backup_file"
}

set_config_value() {
    local key="$1"
    local value="$2"
    
    # 如果配置项已存在 (有或没有#)，则替换
    if grep -qE "^\s*#?\s*${key}" "$SSH_CONFIG_FILE"; then
        sed -i -E "s/^\s*#?\s*${key}.*/${key} ${value}/" "$SSH_CONFIG_FILE"
        msg_ok "配置 '${key}' 已更新为 '${value}'"
    # 否则，在文件末尾添加
    else
        echo "${key} ${value}" >> "$SSH_CONFIG_FILE"
        msg_ok "配置 '${key}' 已添加，值为 '${value}'"
    fi
}

restart_ssh_service() {
    msg_info "正在重启 SSH 服务 (${SSH_SERVICE_NAME})..."
    if command -v systemctl &>/dev/null; then
        systemctl restart "${SSH_SERVICE_NAME}"
    elif command -v service &>/dev/null; then
        service "${SSH_SERVICE_NAME}" restart
    fi
    if [[ $? -eq 0 ]]; then
        msg_ok "SSH 服务重启成功。"
    else
        msg_error "SSH 服务重启失败，请检查服务状态。"
    fi
}

modify_ssh_port() {
    read -p "请输入新的 SSH 端口号 (1-65535): " new_port
    if ! [[ "$new_port" =~ ^[0-9]+$ && "$new_port" -ge 1 && "$new_port" -le 65535 ]]; then
        msg_error "无效的端口号。"
        return
    fi
    backup_config
    set_config_value "Port" "$new_port"
    restart_ssh_service
}

toggle_root_login() {
    read -p "是否允许 root 用户登录? (yes/no): " choice
    if [[ "$choice" != "yes" && "$choice" != "no" ]]; then
        msg_error "无效的输入，请输入 'yes' 或 'no'。"
        return
    fi
    backup_config
    set_config_value "PermitRootLogin" "$choice"
    restart_ssh_service
}

toggle_password_auth() {
    read -p "是否允许使用密码进行身份验证? (yes/no): " choice
    if [[ "$choice" != "yes" && "$choice" != "no" ]]; then
        msg_error "无效的输入，请输入 'yes' 或 'no'。"
        return
    fi
    backup_config
    set_config_value "PasswordAuthentication" "$choice"
    restart_ssh_service
}

show_current_config() {
    clear
    msg_info "--- 当前关键 SSH 配置 ---"
    grep -E "^\s*#?\s*(Port|PermitRootLogin|PasswordAuthentication)" "$SSH_CONFIG_FILE" | sed "s/^#\s*//g"
    echo "---------------------------"
}

main_menu() {
    while true; do
        show_current_config
        echo
        msg_info "请选择要执行的操作:"
        echo "  1) 修改 SSH 端口"
        echo "  2) 允许/禁止 Root 登录"
        echo "  3) 允许/禁止密码登录"
        echo "  4) 仅重启 SSH 服务"
        echo -e "  ${COLOR_RED}0) 退出脚本${COLOR_NC}"
        read -p "请输入选项 [0-4]: " choice

        case "$choice" in
            1) modify_ssh_port ;;
            2) toggle_root_login ;;
            3) toggle_password_auth ;;
            4) restart_ssh_service ;;
            0) msg_ok "脚本已退出。"; exit 0 ;;
            *) msg_error "无效的选项 '$choice'，请重新输入。" ;;
        esac
        echo
        read -n 1 -s -r -p "按任意键返回主菜单..."
        clear
    done
}

# --- 脚本开始 ---
clear
check_root
detect_ssh_config
detect_ssh_service
main_menu
