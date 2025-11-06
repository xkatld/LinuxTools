#!/bin/bash

set -euo pipefail

SSH_CONFIG_FILE=""
SSH_SERVICE_NAME=""
CURRENT_PORT="22"
OS_ID=""
PKG_MANAGER=""
INSTALL_CMD=""
SSH_SERVER_PKG=""

log_info() { echo "[INFO] $1"; }
log_ok() { echo "[OK] $1"; }
log_error() { echo "[ERROR] $1" >&2; }
log_warn() { echo "[WARN] $1"; }

command_exists() {
    command -v "$1" &>/dev/null
}

check_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        log_error "需要 root 权限"
        exit 1
    fi
}

detect_os() {
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        OS_ID=$ID
    else
        log_error "无法检测操作系统"
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
            INSTALL_CMD="yum install -y"
            SSH_SERVER_PKG="openssh-server"
            ;;
        fedora)
            PKG_MANAGER="dnf"
            INSTALL_CMD="dnf install -y"
            SSH_SERVER_PKG="openssh-server"
            ;;
        opensuse*)
            PKG_MANAGER="zypper"
            INSTALL_CMD="zypper install -y"
            SSH_SERVER_PKG="openssh"
            ;;
        *)
            log_error "不支持的操作系统: $OS_ID"
            exit 1
            ;;
    esac
}

check_ssh_host_keys() {
    local key_dir="/etc/ssh"
    local missing_keys=()

    for key_type in rsa ecdsa ed25519; do
        if [[ ! -f "${key_dir}/ssh_host_${key_type}_key" ]]; then
            missing_keys+=("$key_type")
        fi
    done

    if [[ ${#missing_keys[@]} -gt 0 ]]; then
        log_warn "缺失 Host Key: ${missing_keys[*]}"
        log_info "生成 Host Keys..."
        ssh-keygen -A
        log_ok "Host Keys 已生成"
    fi
}

install_ssh_server() {
    if command_exists sshd || command_exists ssh; then
        log_info "SSH 服务器已安装"
        return 0
    fi

    log_info "安装 SSH 服务器..."
    if ! $INSTALL_CMD $SSH_SERVER_PKG; then
        log_error "SSH 安装失败"
        exit 1
    fi
    log_ok "SSH 服务器已安装"
}

initialize_ssh_env() {
    detect_os
    log_info "操作系统: $OS_ID"
    
    install_ssh_server
    check_ssh_host_keys

    if [[ -f /etc/ssh/sshd_config ]]; then
        SSH_CONFIG_FILE="/etc/ssh/sshd_config"
    else
        log_error "未找到 SSH 配置文件"
        exit 1
    fi

    if command_exists systemctl; then
        if systemctl list-unit-files | grep -q "^sshd.service"; then
            SSH_SERVICE_NAME="sshd"
        elif systemctl list-unit-files | grep -q "^ssh.service"; then
            SSH_SERVICE_NAME="ssh"
        else
            log_error "未找到 SSH 服务"
            exit 1
        fi
    else
        SSH_SERVICE_NAME="sshd"
    fi

    CURRENT_PORT=$(grep -E "^Port " "$SSH_CONFIG_FILE" 2>/dev/null | awk '{print $2}' || echo "22")
    log_info "SSH 端口: $CURRENT_PORT"
}

backup_config() {
    cp "$SSH_CONFIG_FILE" "${SSH_CONFIG_FILE}.bak.$(date +%Y%m%d_%H%M%S)"
}

set_config_value() {
    local key="$1"
    local value="$2"
    
    if grep -qE "^${key} " "$SSH_CONFIG_FILE"; then
        sed -i "s/^${key} .*/${key} ${value}/" "$SSH_CONFIG_FILE"
    elif grep -qE "^#${key} " "$SSH_CONFIG_FILE"; then
        sed -i "s/^#${key} .*/${key} ${value}/" "$SSH_CONFIG_FILE"
    else
        echo "${key} ${value}" >> "$SSH_CONFIG_FILE"
    fi
}

test_ssh_config() {
    if command_exists sshd; then
        if sshd -t 2>&1; then
            log_ok "配置文件语法正确"
            return 0
        else
            log_error "配置文件语法错误"
            return 1
        fi
    fi
    return 0
}

restart_ssh_service() {
    if ! test_ssh_config; then
        log_error "配置测试失败，不会重启服务"
        return 1
    fi

    log_info "重启 SSH 服务..."
    if systemctl restart "$SSH_SERVICE_NAME"; then
        log_ok "SSH 服务已重启"
        systemctl enable "$SSH_SERVICE_NAME" &>/dev/null || true
    else
        log_error "SSH 服务重启失败"
        return 1
    fi
}

manage_firewall() {
    local port="$1"
    
    if command_exists ufw && ufw status 2>/dev/null | grep -q "Status: active"; then
        log_info "配置 UFW 防火墙..."
        ufw allow "$port"/tcp >/dev/null
        log_ok "UFW 已允许端口 $port"
    elif command_exists firewall-cmd && systemctl is-active --quiet firewalld; then
        log_info "配置 firewalld..."
        firewall-cmd --permanent --add-port="$port"/tcp >/dev/null
        firewall-cmd --reload >/dev/null
        log_ok "firewalld 已允许端口 $port"
    fi
}

manage_selinux_port() {
    local port="$1"
    
    if command_exists semanage && command_exists getenforce; then
        if [[ "$(getenforce)" != "Disabled" ]]; then
            log_info "配置 SELinux..."
            semanage port -a -t ssh_port_t -p tcp "$port" 2>/dev/null || \
            semanage port -m -t ssh_port_t -p tcp "$port" 2>/dev/null
            log_ok "SELinux 已配置"
        fi
    fi
}

modify_ssh_port() {
    echo ""
    echo "=> 修改 SSH 端口"
    echo ""
    
    local new_port
    read -p "新的 SSH 端口 [默认: 22]: " -r new_port
    new_port=${new_port:-22}
    
    if ! [[ "$new_port" =~ ^[0-9]+$ ]] || [[ "$new_port" -lt 1 ]] || [[ "$new_port" -gt 65535 ]]; then
        log_error "无效的端口号"
        return
    fi

    backup_config
    set_config_value "Port" "$new_port"
    
    manage_firewall "$new_port"
    manage_selinux_port "$new_port"
    
    restart_ssh_service
    CURRENT_PORT="$new_port"
    log_ok "SSH 端口已改为 $new_port"
}

toggle_root_login() {
    echo ""
    echo "=> 配置 Root 登录"
    echo ""
    
    local current
    current=$(grep -E "^PermitRootLogin " "$SSH_CONFIG_FILE" 2>/dev/null | awk '{print $2}' || echo "yes")
    
    echo "当前状态: $current"
    read -p "允许 Root 登录? [y/N]: " -r choice
    choice=${choice:-N}
    
    backup_config
    if [[ "$choice" =~ ^[yY]$ ]]; then
        set_config_value "PermitRootLogin" "yes"
        log_ok "已允许 Root 登录"
    else
        set_config_value "PermitRootLogin" "no"
        log_ok "已禁止 Root 登录"
    fi
    
    restart_ssh_service
}

toggle_password_auth() {
    echo ""
    echo "=> 配置密码认证"
    echo ""
    
    local current
    current=$(grep -E "^PasswordAuthentication " "$SSH_CONFIG_FILE" 2>/dev/null | awk '{print $2}' || echo "yes")
    
    echo "当前状态: $current"
    read -p "允许密码登录? [y/N]: " -r choice
    choice=${choice:-N}
    
    backup_config
    if [[ "$choice" =~ ^[yY]$ ]]; then
        set_config_value "PasswordAuthentication" "yes"
        log_ok "已允许密码登录"
    else
        set_config_value "PasswordAuthentication" "no"
        log_ok "已禁止密码登录"
    fi
    
    restart_ssh_service
}

add_public_key() {
    echo ""
    echo "=> 添加公钥"
    echo ""
    
    read -p "用户名 [默认: root]: " -r username
    username=${username:-root}
    
    local user_home
    user_home=$(eval echo "~$username")
    local ssh_dir="${user_home}/.ssh"
    local auth_keys="${ssh_dir}/authorized_keys"
    
    if [[ ! -d "$ssh_dir" ]]; then
        mkdir -p "$ssh_dir"
        chmod 700 "$ssh_dir"
        chown "$username:$username" "$ssh_dir"
    fi
    
    echo "请粘贴公钥内容 (以空行结束):"
    local pubkey=""
    while IFS= read -r line; do
        [[ -z "$line" ]] && break
        pubkey+="$line"
    done
    
    if [[ -z "$pubkey" ]]; then
        log_error "未输入公钥"
        return
    fi
    
    echo "$pubkey" >> "$auth_keys"
    chmod 600 "$auth_keys"
    chown "$username:$username" "$auth_keys"
    
    log_ok "公钥已添加到 $auth_keys"
}

apply_security_hardening() {
    echo ""
    echo "=> 安全强化配置"
    echo ""
    
    log_warn "将应用以下配置:"
    echo "  - 禁止 Root 登录"
    echo "  - 禁止密码认证"
    echo "  - 禁用空密码"
    echo "  - 禁用 X11 转发"
    echo ""
    
    read -p "确认应用? [Y/n]: " -r confirm
    confirm=${confirm:-Y}
    if [[ ! "$confirm" =~ ^[yY]$ ]]; then
        log_info "已取消"
        return
    fi
    
    backup_config
    
    set_config_value "PermitRootLogin" "no"
    set_config_value "PasswordAuthentication" "no"
    set_config_value "PermitEmptyPasswords" "no"
    set_config_value "X11Forwarding" "no"
    set_config_value "MaxAuthTries" "3"
    set_config_value "ClientAliveInterval" "300"
    set_config_value "ClientAliveCountMax" "2"
    
    restart_ssh_service
    log_ok "安全强化配置已应用"
}

enable_root_password() {
    echo ""
    log_warn "将开启 Root 和密码登录 (不推荐)"
    read -p "确认执行? [y/N]: " -r confirm
    confirm=${confirm:-N}
    if [[ ! "$confirm" =~ ^[yY]$ ]]; then
        log_info "已取消"
        return
    fi
    
    backup_config
    set_config_value "PermitRootLogin" "yes"
    set_config_value "PasswordAuthentication" "yes"
    restart_ssh_service
    log_ok "已开启 Root 和密码登录"
}

show_current_config() {
    local port root_login pass_auth
    port=$(grep -E "^Port " "$SSH_CONFIG_FILE" 2>/dev/null | awk '{print $2}' || echo "22")
    root_login=$(grep -E "^PermitRootLogin " "$SSH_CONFIG_FILE" 2>/dev/null | awk '{print $2}' || echo "yes")
    pass_auth=$(grep -E "^PasswordAuthentication " "$SSH_CONFIG_FILE" 2>/dev/null | awk '{print $2}' || echo "yes")
    
    echo "========================================"
    echo "  SSH 当前配置"
    echo "========================================"
    echo "  端口:     $port"
    echo "  Root登录: $root_login"
    echo "  密码认证: $pass_auth"
    echo "========================================"
}

main_menu() {
    while true; do
        clear 2>/dev/null || printf '\033[2J\033[H'
        show_current_config
        echo ""
        echo "操作选项:"
        echo "  1) 修改 SSH 端口"
        echo "  2) 配置 Root 登录"
        echo "  3) 配置密码认证"
        echo "  4) 添加公钥"
        echo "  5) 安全强化配置"
        echo "  6) 重启 SSH 服务"
        echo "  7) 开启Root和密码登录"
        echo "  0) 退出"
        echo "========================================"
        read -p "请选择 [0-7]: " -r choice

        case "$choice" in
            1) modify_ssh_port ;;
            2) toggle_root_login ;;
            3) toggle_password_auth ;;
            4) add_public_key ;;
            5) apply_security_hardening ;;
            6) restart_ssh_service ;;
            7) enable_root_password ;;
            0) log_info "退出脚本"; exit 0 ;;
            *) log_error "无效选项: $choice" ;;
        esac
        echo ""
        read -n 1 -s -r -p "按任意键继续..."
    done
}

check_root
initialize_ssh_env
main_menu
