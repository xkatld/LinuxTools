#!/bin/bash
#
# +--------------------------------------------------------------------+
# | Script Name:    SSH Manager (v3.0 Smart & Secure)                  |
# | Author:         xkatld & gemini                                    |
# | Description:    一个更安全、更智能、功能更全面的SSH服务管理脚本。  |
# | Features:       自动修复缺失Host Keys, 自动处理防火墙/SELinux,     |
# |                 重启前配置检查, 一键式操作, 安全强化向导, 公钥管理 |
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
readonly COLOR_NC='\033[0m'

# 这些变量将在初始化函数中被赋值
SSH_CONFIG_FILE=""
SSH_SERVICE_NAME=""
CURRENT_PORT="22"

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

check_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        msg_error "此脚本需要 root 权限来安装/修改 SSH 配置和重启服务。"
        exit 1
    fi
}

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

check_ssh_host_keys() {
    if ! ls /etc/ssh/ssh_host_*_key &>/dev/null; then
        msg_error "致命错误: 未在 /etc/ssh/ 目录中找到 SSH 主机密钥 (host keys)。"
        msg_warn "这就是导致 'sshd: no hostkeys available -- exiting' 错误的直接原因。"
        read -p "是否要立即自动为您生成主机密钥? (推荐: y): " confirm_gen_keys
        if [[ "$confirm_gen_keys" =~ ^[yY]$ ]]; then
            msg_info "正在执行 'ssh-keygen -A' 来生成所有类型的主机密钥..."
            if ssh-keygen -A; then
                msg_ok "主机密钥已成功生成！"
            else
                msg_error "主机密钥生成失败。请检查权限或尝试手动运行 'sudo ssh-keygen -A'。"
                exit 1
            fi
        else
            msg_error "用户取消操作。在主机密钥生成之前，SSH 服务无法正常工作。"
            exit 1
        fi
    fi
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
    check_ssh_host_keys

    # --- 优化的服务检测逻辑 ---
    if command_exists "systemctl"; then
        local service_candidates=("sshd.service" "ssh.service")
        for service in "${service_candidates[@]}"; do
            # 使用 'cat' 检查服务单元文件是否存在，比 'list-unit-files' 更可靠
            if systemctl cat "$service" &>/dev/null; then
                SSH_SERVICE_NAME="${service//.service/}" # 移除 .service 后缀
                break
            fi
        done
    elif command_exists "service"; then
        local service_candidates=("sshd" "ssh")
        for service in "${service_candidates[@]}"; do
            if [[ -f "/etc/init.d/${service}" ]]; then
                SSH_SERVICE_NAME="$service"
                break
            fi
        done
    fi

    if [[ -z "$SSH_SERVICE_NAME" ]]; then
        msg_warn "无法自动检测到 SSH 服务 (sshd or ssh)。将无法自动重启服务。"
    else
        msg_ok "成功检测到 SSH 服务: ${SSH_SERVICE_NAME}"
    fi

    if command_exists sshd; then
        # -T 选项可以显示当前生效的配置，比读取文件更准确
        CURRENT_PORT=$(sshd -T | grep -i '^port ' | awk '{print $2}' || echo "22")
    else
        CURRENT_PORT=$(grep -i '^\s*Port' "$SSH_CONFIG_FILE" | awk '{print $2}' | tail -n1 || echo "22")
    fi
}

check_fail2ban() {
    if ! command_exists "fail2ban-client"; then
        msg_warn "建议安装 'fail2ban' 来保护您的 SSH 服务免受暴力破解攻击。"
        msg_warn "您可以使用 '${PKG_MANAGER:-包管理器}' 来安装 'fail2ban'。"
    else
        if systemctl is-active --quiet fail2ban; then
            msg_ok "检测到 fail2ban 正在运行，很好！"
        else
            msg_warn "检测到 fail2ban 已安装但未运行。建议使用 'systemctl start fail2ban' 启动它。"
        fi
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
    local config_file="$3"
    
    # 如果该行已存在 (有或没有#)，则替换它
    if grep -qE "^\s*#?\s*${key}" "$config_file"; then
        sed -i -E "s/^\s*#?\s*${key}.*/${key} ${value}/" "$config_file"
        msg_ok "配置 '${key}' 已更新为 '${value}'"
    else
        # 否则，在文件末尾添加它
        echo "${key} ${value}" >> "$config_file"
        msg_ok "配置 '${key}' 已添加，值为 '${value}'"
    fi
}

test_ssh_config() {
    if ! command_exists "sshd"; then
        msg_warn "未找到 'sshd' 命令，无法测试配置文件，将跳过检查。"
        return 0
    fi
    
    msg_info "正在测试 SSH 配置文件语法..."
    # 使用 -f 指定配置文件进行测试
    if sshd -t -f "$SSH_CONFIG_FILE"; then
        msg_ok "配置文件语法正确！"
        return 0
    else
        msg_error "SSH 配置文件存在语法错误！请在修复前不要重启服务！"
        # 显示具体错误
        sshd -t -f "$SSH_CONFIG_FILE"
        return 1
    fi
}

restart_ssh_service() {
    if [[ -z "$SSH_SERVICE_NAME" ]]; then
        msg_error "未检测到 SSH 服务，无法自动重启。请修复检测问题或手动重启。"
        return
    fi

    # 新增：重启前先测试配置
    if ! test_ssh_config; then
        msg_error "由于配置测试失败，已取消重启操作以保证安全。"
        exit 1
    fi

    msg_info "正在重启 SSH 服务 (${SSH_SERVICE_NAME})..."
    if command_exists "systemctl"; then
        systemctl restart "${SSH_SERVICE_NAME}.service"
    elif command_exists "service"; then
        service "${SSH_SERVICE_NAME}" restart
    else
        msg_error "未找到 systemctl 或 service 命令，无法重启服务。"
        return
    fi

    # 检查服务状态
    sleep 1
    if systemctl is-active --quiet "$SSH_SERVICE_NAME"; then
        msg_ok "SSH 服务重启成功并正在运行。"
    else
        msg_error "SSH 服务重启后未能成功运行。请立即检查服务状态: 'systemctl status ${SSH_SERVICE_NAME}'"
        msg_error "您的配置备份在 ${SSH_CONFIG_FILE}.backup_*"
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
        if [[ "$old_port" != "22" && "$old_port" != "$new_port" ]]; then
             firewall-cmd --permanent --remove-port="${old_port}/tcp" || true
        fi
        firewall-cmd --reload
        msg_ok "firewalld 规则已更新。"
    elif command_exists "ufw"; then
        msg_info "检测到 ufw，正在更新规则..."
        ufw allow "${new_port}/tcp"
        if [[ "$old_port" != "22" && "$old_port" != "$new_port" ]]; then
             ufw delete allow "${old_port}/tcp" >/dev/null 2>&1 || true
        fi
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
            msg_warn "检测到 SELinux，但 'semanage' 命令未找到 (请安装 'policycoreutils-python-utils')。请手动配置SELinux！"
        fi
    fi
}

modify_ssh_port() {
    msg_warn "!!! 修改SSH端口是高危操作 !!!"
    msg_warn "错误的操作可能导致您无法再次连接到服务器。"
    read -p "请输入新的 SSH 端口号 (1024-65535)，或按 Enter 取消: " new_port
    
    if [[ -z "$new_port" ]]; then
        msg_info "操作已取消。"
        return
    fi

    if ! [[ "$new_port" =~ ^[0-9]+$ && "$new_port" -ge 1024 && "$new_port" -le 65535 ]]; then
        msg_error "无效的端口号。推荐使用 1024 以上的端口。"
        return
    fi

    backup_config
    set_config_value "Port" "$new_port" "$SSH_CONFIG_FILE"
    
    manage_selinux_port "$new_port"
    manage_firewall "$new_port" "$CURRENT_PORT"

    restart_ssh_service
    CURRENT_PORT="$new_port"
    msg_ok "SSH 端口已成功修改为 ${new_port}。请记得使用新端口连接！"
}

toggle_root_login() {
    read -p "是否允许 root 用户登录? (yes/no/without-password): " choice
    if [[ "$choice" != "yes" && "$choice" != "no" && "$choice" != "without-password" ]]; then
        msg_error "无效的输入，请输入 'yes', 'no' 或 'without-password'."
        return
    fi
    backup_config
    set_config_value "PermitRootLogin" "$choice" "$SSH_CONFIG_FILE"
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
    set_config_value "PasswordAuthentication" "$choice" "$SSH_CONFIG_FILE"
    restart_ssh_service
}

one_click_insecure_setup() {
    msg_warn "此操作将允许 root 用户使用密码直接登录，存在安全风险！"
    msg_warn "仅建议在安全的内部网络或临时维护时使用。"
    read -p "确认要同时开启 Root 登录和密码登录吗? (y/N): " confirm
    if [[ ! "$confirm" =~ ^[yY]$ ]]; then
        msg_info "操作已取消。"
        return
    fi
    
    backup_config
    set_config_value "PermitRootLogin" "yes" "$SSH_CONFIG_FILE"
    set_config_value "PasswordAuthentication" "yes" "$SSH_CONFIG_FILE"
    restart_ssh_service
    msg_ok "已同时开启 Root 登录和密码认证。"
}

add_authorized_key() {
    local default_user
    default_user=$(logname 2>/dev/null || echo "root")
    read -p "请输入要添加公钥的用户名 [默认: ${default_user}]: " user
    user=${user:-$default_user}

    if ! id "$user" &>/dev/null; then
        msg_error "用户 '$user' 不存在。"
        return
    fi

    local user_home
    user_home=$(eval echo "~$user")
    local ssh_dir="${user_home}/.ssh"
    local auth_keys_file="${ssh_dir}/authorized_keys"

    msg_info "准备为用户 '${user}' 添加公钥到 '${auth_keys_file}'"
    read -p "请粘贴您的公钥 (例如 ssh-rsa AAAA...): " pub_key

    if [[ -z "$pub_key" ]]; then
        msg_error "公钥不能为空。"
        return
    fi

    # 创建目录和文件 (如果不存在)
    mkdir -p "$ssh_dir"
    touch "$auth_keys_file"

    # 添加公钥
    echo "$pub_key" >> "$auth_keys_file"
    
    # 设置正确的权限
    chown -R "${user}:${user}" "$ssh_dir"
    chmod 700 "$ssh_dir"
    chmod 600 "$auth_keys_file"
    
    msg_ok "公钥已成功添加到 '${user}' 的授权列表。"
    msg_info "权限已设置为: ${ssh_dir} (700), ${auth_keys_file} (600)。"
}

apply_security_hardening() {
    msg_info "--- SSH 安全强化向导 ---"
    msg_warn "此向导将引导您应用一系列安全最佳实践。"
    
    local changes_made=0
    local temp_config_file
    temp_config_file=$(mktemp)
    cp "$SSH_CONFIG_FILE" "$temp_config_file"
    
    read -p "1. 是否禁用密码认证 (强烈推荐，请先确保已添加公钥)? (y/N): " confirm
    if [[ "$confirm" =~ ^[yY]$ ]]; then
        set_config_value "PasswordAuthentication" "no" "$temp_config_file"
        changes_made=1
    fi
    
    read -p "2. 是否禁止 root 用户登录 (强烈推荐)? (y/N): " confirm
    if [[ "$confirm" =~ ^[yY]$ ]]; then
        set_config_value "PermitRootLogin" "no" "$temp_config_file"
        changes_made=1
    fi

    read -p "3. 是否将最大认证尝试次数设为 3? (y/N): " confirm
    if [[ "$confirm" =~ ^[yY]$ ]]; then
        set_config_value "MaxAuthTries" "3" "$temp_config_file"
        changes_made=1
    fi
    
    read -p "4. 是否将登录宽限时间设为 60 秒? (y/N): " confirm
    if [[ "$confirm" =~ ^[yY]$ ]]; then
        set_config_value "LoginGraceTime" "60" "$temp_config_file"
        changes_made=1
    fi
    
    read -p "5. 是否禁用 X11 转发 (除非您需要图形界面转发)? (y/N): " confirm
    if [[ "$confirm" =~ ^[yY]$ ]]; then
        set_config_value "X11Forwarding" "no" "$temp_config_file"
        changes_made=1
    fi

    if [[ "$changes_made" -eq 1 ]]; then
        backup_config
        mv "$temp_config_file" "$SSH_CONFIG_FILE"
        msg_ok "安全配置已应用。"
        restart_ssh_service
    else
        rm "$temp_config_file"
        msg_info "未做任何更改。"
    fi
}

show_current_config() {
    msg_info "--- 当前生效的 SSH 关键配置 ---"
    if command_exists sshd; then
        sshd -T | grep -iE '^(port|permitrootlogin|passwordauthentication|maxauthtries|logingracetime|x11forwarding)'
    else
        msg_warn "无法使用 'sshd -T'，将从配置文件读取，可能不完全准确。"
        grep -iE "^\s*#?\s*(Port|PermitRootLogin|PasswordAuthentication|MaxAuthTries|LoginGraceTime|X11Forwarding)" "$SSH_CONFIG_FILE" | sed "s/^#\s*//g"
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
        echo -e "  ${COLOR_YELLOW}4) 添加公钥到 authorized_keys${COLOR_NC}"
        echo -e "  ${COLOR_YELLOW}5) 应用安全强化配置 (向导)${COLOR_NC}"
        echo "  6) 仅重启 SSH 服务"
        echo -e "  ${COLOR_RED}7) 一键开启Root和密码登录 (不推荐)${COLOR_NC}"
        echo
        echo -e "  ${COLOR_RED}0) 退出脚本${COLOR_NC}"
        read -p "请输入选项 [0-7]: " choice

        case "$choice" in
            1) modify_ssh_port ;;
            2) toggle_root_login ;;
            3) toggle_password_auth ;;
            4) add_authorized_key ;;
            5) apply_security_hardening ;;
            6) restart_ssh_service ;;
            7) one_click_insecure_setup ;;
            0) msg_ok "脚本已退出。"; exit 0 ;;
            *) msg_error "无效的选项 '$choice'，请重新输入。" ;;
        esac
        echo
        read -n 1 -s -r -p "按任意键返回主菜单..."
    done
}

# --- 脚本执行入口 ---
clear_screen
check_root
detect_os
initialize_ssh_env
check_fail2ban # 在显示菜单前检查一次
main_menu