#!/bin/bash
#
# +--------------------------------------------------------------------+
# | Script Name:    SSH Manager (v2.1 Full-Featured)                   |
# | Author:         xkatld & gemini                                    |
# | Description:    一个安全、智能的SSH服务管理脚本。                  |
# | Features:       自动检测并安装SSH服务, 自动处理防火墙和SELinux。   |
# +--------------------------------------------------------------------+

set -o errexit
set -o nounset
set -o pipefail

# --- 全局变量与常量 ---
readonly COLOR_GREEN='\033[0;32m'
readonly COLOR_RED='\033[0;31m'
readonly COLOR_YELLOW='\033[1;33m'
readonly COLOR_CYAN='\033[0;36m'
readonly COLOR_NC='\033[0m'

# 这两个变量将在初始化函数中被赋值
SSH_CONFIG_FILE=""
SSH_SERVICE_NAME=""
CURRENT_PORT="22" # 默认端口

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

install_ssh_server() {
    msg_warn "未检测到 OpenSSH 服务器。是否立即安装？"
    read -p "请输入 'y' 进行安装，或按其他任意键退出: " confirm
    if [[ ! "$confirm" =~ ^[yY]$ ]]; then
        msg_info "操作已由用户取消。"
        exit 0
    fi
    
    msg_info "正在尝试安装 OpenSSH Server..."
    if command_exists "apt-get"; then
        msg_info "检测到 APT 包管理器 (Debian/Ubuntu)..."
        apt-get update
        apt-get install -y openssh-server
    elif command_exists "yum"; then
        msg_info "检测到 YUM 包管理器 (CentOS/RHEL)..."
        yum install -y openssh-server
    elif command_exists "dnf"; then
        msg_info "检测到 DNF 包管理器 (Fedora/RHEL)..."
        dnf install -y openssh-server
    else
        msg_error "未找到支持的包管理器 (apt, yum, dnf)。请手动安装 openssh-server。"
        exit 1
    fi
    
    if ! command_exists "sshd"; then
        msg_error "OpenSSH Server 安装失败，请检查安装日志。"
        exit 1
    fi
    
    msg_ok "OpenSSH Server 安装成功！正在重新初始化环境..."
    # 清空变量，以便重新检测
    SSH_CONFIG_FILE=""
    SSH_SERVICE_NAME=""
    # 递归调用初始化函数来设置新环境
    initialize_ssh_env
}

check_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        msg_error "此脚本需要 root 权限来安装/修改 SSH 配置和重启服务。"
        exit 1
    fi
}

# 检测 SSH 配置文件、服务和当前端口
initialize_ssh_env() {
    # 检测配置文件
    local possible_configs=("/etc/ssh/sshd_config" "/etc/sshd_config" "/etc/openssh/sshd_config")
    for config in "${possible_configs[@]}"; do
        if [[ -f "$config" ]]; then
            SSH_CONFIG_FILE="$config"
            break
        fi
    done
    
    # 如果找不到配置文件，则触发安装流程
    if [[ -z "$SSH_CONFIG_FILE" ]]; then
        install_ssh_server
        return # 安装函数会处理后续逻辑或退出
    fi
    
    msg_info "检测到 SSH 配置文件: ${SSH_CONFIG_FILE}"

    # 检测服务名
    if command_exists "systemctl"; then
        for service in sshd ssh; do
            if systemctl list-units --type=service --all | grep -q "${service}.service"; then
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

    # 获取当前端口 (优先使用sshd -T的精确值)
    if command_exists sshd; then
        CURRENT_PORT=$(sshd -T | grep -i '^port ' | awk '{print $2}' || echo "22")
    else
        CURRENT_PORT=$(grep -i '^\s*Port' "$SSH_CONFIG_FILE" | awk '{print $2}' | tail -n1 || echo "22")
    fi
}

# --- 核心管理功能 (这部分代码保持不变，此处省略以便聚焦修改点) ---
# backup_config(), set_config_value(), restart_ssh_service(), ...
# ... (此处粘贴之前版本中从 backup_config 到 show_current_config 的所有函数)
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
        systemctl restart "${SSH_SERVICE_NAME}"
    elif command_exists "service"; then
        service "${SSH_SERVICE_NAME}" restart
    fi

    if [[ $? -eq 0 ]]; then
        msg_ok "SSH 服务重启成功。"
    else
        msg_error "SSH 服务重启失败，请检查服务状态和配置文件。您可能需要从备份中恢复。"
        exit 1 # 重启失败是严重问题，直接退出
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
        firewall-cmd --permanent --add-port=${new_port}/tcp
        if [[ "$old_port" != "22" ]]; then # 不要移除默认的22端口服务，以防万一
             firewall-cmd --permanent --remove-port=${old_port}/tcp || true
        fi
        firewall-cmd --reload
        msg_ok "firewalld 规则已更新。"
    elif command_exists "ufw"; then
        msg_info "检测到 ufw，正在更新规则..."
        ufw allow ${new_port}/tcp
        ufw delete allow ${old_port}/tcp || true
        msg_ok "ufw 规则已更新。"
    fi
}

manage_selinux_port() {
    local new_port=$1
    if command_exists "sestatus" && sestatus | grep -q "SELinux status:\s*enabled"; then
        msg_info "检测到 SELinux 已启用。"
        if command_exists "semanage"; then
            msg_info "正在为新端口 ${new_port} 添加 SELinux 上下文..."
            semanage port -a -t ssh_port_t -p tcp "$new_port" || msg_warn "添加SELinux端口上下文失败，可能已存在。"
            msg_ok "SELinux 端口上下文已处理。"
        else
            msg_warn "检测到 SELinux，但 'semanage' 命令未找到 (请安装 policycoreutils-python-utils 或类似包)。请手动配置SELinux！"
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
    
    # 智能处理 SELinux 和防火墙
    manage_selinux_port "$new_port"
    manage_firewall "$new_port" "$CURRENT_PORT"

    restart_ssh_service
    CURRENT_PORT="$new_port" # 更新当前端口状态
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
    msg_info "--- 当前生效的 SSH 关键配置 (来自 sshd -T) ---"
    if command_exists sshd; then
        # 使用 sshd -T 获取最准确的当前生效配置
        sshd -T | grep -iE '^(port|permitrootlogin|passwordauthentication)'
    else
        # 降级方案：如果 sshd 命令不可用，则从文件 grep
        msg_warn "无法使用 'sshd -T'，配置可能不完全准确。"
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
initialize_ssh_env
main_menu
