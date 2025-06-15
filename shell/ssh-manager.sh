#!/bin/bash
#
# +--------------------------------------------------------------------+
# | Script Name:    SSH Manager (v2.2 Multi-Distro)                    |
# | Author:         xkatld & gemini                                    |
# | Description:    一个安全、智能的SSH服务管理脚本。                  |
# | Features:       自动检测并安装SSH服务, 自动处理防火墙和SELinux。   |
# | Compatibility:  Debian, Ubuntu, CentOS, RHEL, Fedora, AlmaLinux,   |
# |                 Rocky Linux, openSUSE                              |
# +--------------------------------------------------------------------+

set -o errexit
set -o nounset
set -o pipefail

# --- 全局变量与常量 ---
readonly COLOR_GREEN='\033[0;32m'
readonly COLOR_RED='\033[0;31m'
readonly COLOR_YELLOW='\033[1;33m'
readonly COLOR_CYAN='\033[0;36m'
readonly COLOR_NC='\033[0m' # No Color

# 这些变量将在初始化函数中被赋值
SSH_CONFIG_FILE=""
SSH_SERVICE_NAME=""
CURRENT_PORT="22" # 默认端口

# OS-specific variables
OS_ID=""
PKG_MANAGER=""
INSTALL_CMD=""
SSH_SERVER_PKG=""

# --- 消息与日志函数 ---
msg_info() { echo -e "${COLOR_CYAN}[*] $1${COLOR_NC}"; }
msg_ok() { echo -e "${COLOR_GREEN}[+] $1${COLOR_NC}"; }
msg_error() { echo -e "${COLOR_RED}[!] 错误: $1${COLOR_NC}" >&2; }
msg_warn() { echo -e "${COLOR_YELLOW}[-] 警告: $1${COLOR_NC}"; }

# --- 辅助函数 ---

command_exists() {
    command -v "$1" &>/dev/null
}

clear_screen() {
    if command_exists "clear"; then
        clear
    else
        printf '\033[2J\033[H'
    fi
}

# --- 安装与初始化函数 ---

detect_os() {
    if [ -f /etc/os-release ]; then
        # shellcheck source=/dev/null
        . /etc/os-release
        OS_ID=$ID
    else
        msg_error "无法检测到操作系统，/etc/os-release 文件不存在。"
        exit 1
    fi

    case "$OS_ID" in
        ubuntu|debian)
            PKG_MANAGER="apt-get"
            INSTALL_CMD="apt-get install -y"
            SSH_SERVER_PKG="openssh-server"
            ;;
        centos|rhel|almalinux|rocky)
            PKG_MANAGER="yum"
            if command_exists "dnf"; then PKG_MANAGER="dnf"; fi
            INSTALL_CMD="$PKG_MANAGER install -y"
            SSH_SERVER_PKG="openssh-server"
            ;;
        fedora)
            PKG_MANAGER="dnf"
            INSTALL_CMD="dnf install -y"
            SSH_SERVER_PKG="openssh-server"
            ;;
        opensuse*|sles)
            PKG_MANAGER="zypper"
            INSTALL_CMD="zypper install -y --no-confirm"
            SSH_SERVER_PKG="openssh"
            ;;
        *)
            msg_error "不支持的操作系统: $OS_ID. 将无法自动安装软件包。"
            ;;
    esac
    msg_info "检测到操作系统: $OS_ID, 包管理器: ${PKG_MANAGER:-'未识别'}"
}

install_ssh_server() {
    msg_warn "未检测到 OpenSSH 服务器。是否立即安装？"
    read -p "请输入 'y' 进行安装，或按其他任意键退出: " confirm
    if [[ ! "$confirm" =~ ^[yY]$ ]]; then
        msg_info "操作已由用户取消。"
        exit 0
    fi
    
    if [[ -z "$PKG_MANAGER" || -z "$INSTALL_CMD" || -z "$SSH_SERVER_PKG" ]]; then
        msg_error "由于操作系统不受支持或无法识别，无法自动安装。请手动安装 SSH 服务器。"
        exit 1
    fi

    msg_info "正在尝试使用 ${PKG_MANAGER} 安装 ${SSH_SERVER_PKG}..."
    
    if [[ "$PKG_MANAGER" == "apt-get" ]]; then
        msg_info "正在运行 'apt-get update'..."
        apt-get update
    fi

    if eval "$INSTALL_CMD $SSH_SERVER_PKG"; then
        msg_ok "${SSH_SERVER_PKG} 安装成功！"
    else
        msg_error "${SSH_SERVER_PKG} 安装失败，请检查安装日志。"
        exit 1
    fi
    
    if ! command_exists "sshd"; then
        msg_error "sshd 命令依然未找到，安装可能已失败。"
        exit 1
    fi
    
    msg_info "正在重新初始化环境..."
    SSH_CONFIG_FILE=""
    SSH_SERVICE_NAME=""
    initialize_ssh_env
}

check_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        msg_error "此脚本需要 root 权限来安装/修改 SSH 配置和重启服务。"
        exit 1
    fi
}

initialize_ssh_env() {
    local possible_configs=("/etc/ssh/sshd_config" "/etc/sshd_config" "/etc/openssh/sshd_config")
    for config in "${possible_configs[@]}"; do
        if [[ -f "$config" ]]; then
            SSH_CONFIG_FILE="$config"
            break
        fi
    done
    
    if [[ -z "$SSH_CONFIG_FILE" ]]; then
        install_ssh_server
        return
    fi
    
    msg_info "检测到 SSH 配置文件: ${SSH_CONFIG_FILE}"

    if command_exists "systemctl"; then
        local service_candidates=("sshd" "ssh")
        for service in "${service_candidates[@]}"; do
            if systemctl list-unit-files --type=service | grep -q "^${service}\.service"; then
                SSH_SERVICE_NAME="$service"
                break
            fi
        done
    elif command_exists "service"; then
        for service in sshd ssh; do
            if [[ -f "/etc/init.d/${service}" ]]; then
                SSH_SERVICE_NAME="$service"
                break
            fi
        done
    fi

    if [[ -z "$SSH_SERVICE_NAME" ]]; then
        msg_warn "未找到 systemd 或 init.d 的 SSH 服务。将无法自动重启服务。"
    else
        msg_info "检测到 SSH 服务: ${SSH_SERVICE_NAME}"
    fi

    if command_exists sshd; then
        CURRENT_PORT=$(sshd -T | grep -i '^port ' | awk '{print $2}' || echo "22")
    else
        CURRENT_PORT=$(grep -i '^\s*Port' "$SSH_CONFIG_FILE" | awk '{print $2}' | tail -n1 || echo "22")
    fi
}

# --- 核心管理功能 ---
backup_config() {
    local backup_file="${SSH_CONFIG_FILE}.backup_$(date +%Y%m%d_%H%M%S)"
    msg_info "正在备份当前配置到: ${backup_file}"
    cp "$SSH_CONFIG_FILE" "$backup_file"
}

set_config_value() {
    local key="$1"
    local value="$2"
    
    if grep -qE "^\s*#?\s*${key}" "$SSH_CONFIG_FILE"; then
        sed -i -E "s/^\s*#?\s*${key}.*/${key} ${value}/" "$SSH_CONFIG_FILE"
        msg_ok "配置 '${key}' 已更新为 '${value}'"
    else
        echo "${key} ${value}" >> "$SSH_CONFIG_FILE"
        msg_ok "配置 '${key}' 已添加，值为 '${value}'"
    fi
}

restart_ssh_service() {
    if [[ -z "$SSH_SERVICE_NAME" ]]; then
        msg_warn "未检测到 SSH 服务，请手动重启。"
        return
    fi

    msg_info "正在重启 SSH 服务 (${SSH_SERVICE_NAME})..."
    if command_exists "systemctl"; then
        systemctl restart "${SSH_SERVICE_NAME}.service"
    elif command_exists "service"; then
        service "${SSH_SERVICE_NAME}" restart
    fi

    if [[ $? -eq 0 ]]; then
        msg_ok "SSH 服务重启成功。"
    else
        msg_error "SSH 服务重启失败，请检查服务状态和配置文件。您可能需要从备份中恢复。"
        exit 1
    fi
}

manage_firewall() {
    local new_port=$1
    local old_port=$2

    if ! command_exists "firewall-cmd" && ! command_exists "ufw"; then
        msg_warn "未检测到 firewalld 或 ufw，跳过防火墙配置。请记得手动允许新端口！"
        return
    fi

    read -p "是否需要自动更新防火墙规则? (y/N): " confirm
    if [[ ! "$confirm" =~ ^[yY]$ ]]; then
        msg_warn "跳过防火墙配置。请记得手动允许新端口 ${new_port}！"
        return
    fi

    if command_exists "firewall-cmd"; then
        msg_info "检测到 firewalld，正在更新规则..."
        firewall-cmd --permanent --add-port="${new_port}/tcp"
        if [[ "$old_port" != "22" ]]; then
             firewall-cmd --permanent --remove-port="${old_port}/tcp" || true
        fi
        firewall-cmd --reload
        msg_ok "firewalld 规则已更新。"
    elif command_exists "ufw"; then
        msg_info "检测到 ufw，正在更新规则..."
        ufw allow "${new_port}/tcp"
        ufw delete allow "${old_port}/tcp" >/dev/null 2>&1 || true
        msg_ok "ufw 规则已更新。"
    fi
}

manage_selinux_port() {
    local new_port=$1
    if command_exists "sestatus" && sestatus | grep -q "SELinux status:\s*enabled"; then
        msg_info "检测到 SELinux 已启用。"
        if command_exists "semanage"; then
            msg_info "正在为新端口 ${new_port} 添加 SELinux 上下文..."
            if semanage port -a -t ssh_port_t -p tcp "$new_port" &>/dev/null; then
                msg_ok "SELinux 端口上下文已成功添加。"
            else
                msg_info "添加 SELinux 端口上下文失败，可能已存在，尝试修改..."
                if semanage port -m -t ssh_port_t -p tcp "$new_port" &>/dev/null; then
                    msg_ok "SELinux 端口上下文已成功修改。"
                else
                    msg_warn "添加或修改 SELinux 端口上下文失败。请手动检查: semanage port -l | grep ssh"
                fi
            fi
        else
            msg_warn "检测到 SELinux，但 'semanage' 命令未找到 (请安装提供此命令的包，例如 'policycoreutils-python-utils')。请手动配置SELinux！"
        fi
    fi
}

modify_ssh_port() {
    msg_warn "!!! 修改SSH端口是高危操作 !!!"
    msg_warn "错误的操作可能导致您无法再次连接到服务器。"
    read -p "请输入新的 SSH 端口号 (1-65535)，或按 Enter 取消: " new_port
    
    if [[ -z "$new_port" ]]; then
        msg_info "操作已取消。"
        return
    fi

    if ! [[ "$new_port" =~ ^[0-9]+$ && "$new_port" -ge 1 && "$new_port" -le 65535 ]]; then
        msg_error "无效的端口号。"
        return
    fi

    backup_config
    set_config_value "Port" "$new_port"
    
    manage_selinux_port "$new_port"
    manage_firewall "$new_port" "$CURRENT_PORT"

    restart_ssh_service
    CURRENT_PORT="$new_port"
    msg_ok "SSH 端口已成功修改为 ${new_port}。请记得使用新端口连接！"
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
    msg_warn "在禁用密码登录前，请务必确认您已配置好 SSH 密钥登录！"
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
    msg_info "--- 当前生效的 SSH 关键配置 ---"
    if command_exists sshd; then
        sshd -T | grep -iE '^(port|permitrootlogin|passwordauthentication)'
    else
        msg_warn "无法使用 'sshd -T'，将从配置文件读取，可能不完全准确。"
        grep -iE "^\s*#?\s*(Port|PermitRootLogin|PasswordAuthentication)" "$SSH_CONFIG_FILE" | sed "s/^#\s*//g"
    fi
    echo "--------------------------------------------------"
}

# --- 主菜单与脚本入口 ---

main_menu() {
    while true; do
        clear_screen
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
    done
}

# --- 脚本执行入口 ---
check_root
detect_os
initialize_ssh_env
main_menu
