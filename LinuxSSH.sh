#!/bin/bash

#================================================================================
# 脚本名称: LinuxSSH.sh (全面优化版)
# 功    能: 安全地配置SSH服务，包括安装、设置密码、更换端口、并提供备份与回滚机制
#================================================================================

# --- 全局变量和颜色定义 ---
readonly SSHD_CONFIG="/etc/ssh/sshd_config"
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# --- 函数定义 ---

# 打印信息
info() {
    echo -e "${GREEN}[信息] $1${NC}"
}

# 打印警告
warn() {
    echo -e "${YELLOW}[警告] $1${NC}"
}

# 打印错误并退出
error() {
    echo -e "${RED}[错误] $1${NC}"
    exit 1
}

# 检查脚本是否以root权限运行
check_root() {
    if [[ $EUID -ne 0 ]]; then
       error "此脚本必须以root权限运行"
    fi
}

# 备份原始的sshd_config文件
backup_config() {
    if [ -f "$SSHD_CONFIG" ]; then
        local backup_file="${SSHD_CONFIG}.bak.$(date +%Y%m%d-%H%M%S)"
        info "正在备份当前SSH配置文件到: $backup_file"
        cp "$SSHD_CONFIG" "$backup_file"
    else
        error "找不到SSH配置文件: $SSHD_CONFIG"
    fi
}

# 检查并安装OpenSSH Server
install_sshd() {
    if command -v sshd &>/dev/null; then
        info "OpenSSH server 已安装。"
        return
    fi
    
    warn "未检测到 OpenSSH server。"
    local PKG_MANAGER=""
    local INSTALL_CMD=""
    local UPDATE_CMD=""
    local SSH_PACKAGE="openssh-server"

    if command -v apt-get &>/dev/null; then
        PKG_MANAGER="apt"
        INSTALL_CMD="apt-get install -y"; UPDATE_CMD="apt-get update"
    elif command -v dnf &>/dev/null; then
        PKG_MANAGER="dnf"; INSTALL_CMD="dnf install -y"
    elif command -v yum &>/dev/null; then
        PKG_MANAGER="yum"; INSTALL_CMD="yum install -y"
    elif command -v pacman &>/dev/null; then
        PKG_MANAGER="pacman"; INSTALL_CMD="pacman -S --noconfirm"; SSH_PACKAGE="openssh"
    elif command -v zypper &>/dev/null; then
        PKG_MANAGER="zypper"; INSTALL_CMD="zypper install -y"; SSH_PACKAGE="openssh"
    elif command -v apk &>/dev/null; then
        PKG_MANAGER="apk"; INSTALL_CMD="apk add"; UPDATE_CMD="apk update"; SSH_PACKAGE="openssh"
    else
        error "无法检测到支持的包管理器。请手动安装 OpenSSH server。"
    fi
    
    info "使用 $PKG_MANAGER 正在安装 $SSH_PACKAGE ..."
    [ -n "$UPDATE_CMD" ] && $UPDATE_CMD
    $INSTALL_CMD $SSH_PACKAGE || error "$SSH_PACKAGE 安装失败。"
}

# 检查端口是否被占用
check_port_availability() {
    local port=$1
    info "正在检查端口 $port 是否可用..."
    if (command -v ss &>/dev/null && ss -tln | grep -q ":$port ") || (command -v netstat &>/dev/null && netstat -tln | grep -q ":$port "); then
        return 1
    else
        return 0
    fi
}

# 获取用户输入
get_user_input() {
    while true; do
        read -s -p "请输入新的root密码 (输入内容不回显): " password
        echo
        read -s -p "请再次输入以确认: " password_confirm
        echo
        if [ "$password" == "$password_confirm" ]; then
            if [ -z "$password" ]; then
                warn "密码不能为空，请重新输入。"
            else
                info "密码已确认。"
                break
            fi
        else
            warn "两次输入的密码不匹配，请重新输入。"
        fi
    done

    while true; do
        read -p "请输入新的SSH端口 (1-65535): " port
        if ! [[ "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
            warn "无效的端口号。请输入1-65535之间的数字。"
            continue
        fi
        if ! check_port_availability "$port"; then
            warn "端口 $port 已被占用，请选择其他端口。"
            continue
        fi
        info "端口 $port 可用。"
        break
    done
}

# 应用配置更改
apply_config_changes() {
    info "正在应用配置更改..."
    echo "root:$password" | chpasswd || error "设置root密码失败。"

    sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin yes/' "$SSHD_CONFIG"
    sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' "$SSHD_CONFIG"
    
    if grep -q "^#\?Port" "$SSHD_CONFIG"; then
        sed -i "s/^#\?Port.*/Port $port/" "$SSHD_CONFIG"
    else
        echo "Port $port" >> "$SSHD_CONFIG"
    fi
}

# 测试SSH配置文件的语法
test_config() {
    info "正在测试SSH配置文件语法..."
    if sshd -t; then
        info "配置文件语法正确。"
        return 0
    else
        error "SSH配置文件语法错误！"
        return 1
    fi
}

# 配置防火墙
configure_firewall() {
    if command -v firewall-cmd &>/dev/null && systemctl is-active --quiet firewalld; then
        info "检测到 firewalld 正在运行。"
        read -p "是否要为端口 $port 添加入站规则? (y/n): " choice
        if [[ "$choice" == "y" || "$choice" == "Y" ]]; then
            firewall-cmd --permanent --add-port=${port}/tcp
            firewall-cmd --reload
            info "firewalld 已为端口 $port 开放。"
        fi
    elif command -v ufw &>/dev/null && ufw status | grep -q "Status: active"; then
        info "检测到 ufw 正在运行。"
        read -p "是否要为端口 $port 添加入站规则? (y/n): " choice
        if [[ "$choice" == "y" || "$choice" == "Y" ]]; then
            ufw allow ${port}/tcp
            info "ufw 已为端口 $port 开放。"
        fi
    fi
}

# 重启SSH服务
restart_ssh_service() {
    local service_name="sshd"
    if command -v systemctl &>/dev/null; then
        if systemctl list-unit-files | grep -q '^ssh.service'; then
            service_name="ssh"
        fi
        info "正在重启 $service_name 服务..."
        systemctl restart "$service_name" || error "重启 $service_name 服务失败。"
    elif command -v service &>/dev/null; then
         if [ -f /etc/init.d/ssh ]; then
            service_name="ssh"
        fi
        info "正在重启 $service_name 服务..."
        service "$service_name" restart || error "重启 $service_name 服务失败。"
    else
        error "无法自动重启SSH服务，请手动操作。"
    fi
}

# --- 主函数 ---
main() {
    check_root
    install_sshd
    get_user_input
    
    local original_config=$(cat "$SSHD_CONFIG")
    backup_config
    apply_config_changes
    
    if ! test_config; then
        warn "操作已中止，正在恢复原始配置文件..."
        echo "$original_config" > "$SSHD_CONFIG"
        error "已恢复原始配置，系统未做任何更改。"
    fi
    
    configure_firewall
    restart_ssh_service
    
    echo -e "\n======================= ${GREEN}配置完成${NC} ======================="
    info "root密码已更新。"
    info "SSH端口已更改为: $port"
    info "允许root用户通过密码登录。"
    warn "出于安全考虑，强烈建议您创建一个普通用户，并使用SSH密钥进行登录，然后禁用root密码登录。"
    echo "==========================================================="
}

# --- 执行脚本 ---
main
