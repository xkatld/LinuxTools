#!/bin/bash

#================================================================================
# 脚本名称: LinuxSSH.sh (最终修正版)
# 功    能: 自动修复并安全地配置SSH服务，兼容主流发行版、防火墙及SELinux
# 修正内容: 自动检测并生成缺失的SSH主机密钥，解决'no hostkeys available'错误
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

# === 新增的核心修正功能：检查并生成SSH主机密钥 ===
generate_ssh_host_keys_if_missing() {
    # 检查关键的主机密钥文件是否存在
    if [ ! -f "/etc/ssh/ssh_host_rsa_key" ] || [ ! -f "/etc/ssh/ssh_host_ecdsa_key" ] || [ ! -f "/etc/ssh/ssh_host_ed25519_key" ]; then
        warn "一个或多个 SSH 主机密钥 (Host Key) 文件丢失。"
        info "这是导致 'no hostkeys available' 错误的根本原因。"
        info "正在尝试自动生成所有必需的 SSH 主机密钥..."
        
        # 使用 ssh-keygen -A 标志是生成所有类型密钥最简单、最可靠的方法
        ssh-keygen -A
        
        if [ $? -eq 0 ]; then
            info "SSH 主机密钥已成功生成。"
        else
            error "自动生成 SSH 主机密钥失败。请检查权限或手动运行 'ssh-keygen -A' 后再试。"
        fi
    else
        info "SSH 主机密钥完整，无需操作。"
    fi
}

# 检查端口是否被占用
check_port_availability() {
    local port=$1
    info "正在检查端口 $port 是否可用..."
    if (command -v ss &>/dev/null && ss -tln | awk '{print $4}' | grep -q ":${port}$") || \
       (command -v netstat &>/dev/null && netstat -tln | awk '{print $4}' | grep -q ":${port}$"); then
        return 1 # 端口被占用
    else
        return 0 # 端口可用
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
        read -p "请输入新的SSH端口 (1-65535, 建议22以外的端口): " port
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

    # 内部函数：用于健壮地更新或添加配置项
    update_or_add_config() {
        local key="$1"
        local value="$2"
        local file="$3"
        if grep -qE "^[[:space:]]*#?[[:space:]]*${key}" "${file}"; then
            sed -i -E "s/^[[:space:]]*#?[[:space:]]*${key}.*/${key} ${value}/" "${file}"
        else
            echo "${key} ${value}" >> "${file}"
        fi
    }

    info "确保允许 Root 登录和密码认证..."
    update_or_add_config "PermitRootLogin" "yes" "$SSHD_CONFIG"
    update_or_add_config "PasswordAuthentication" "yes" "$SSHD_CONFIG"
    
    info "设置 SSH 端口..."
    update_or_add_config "Port" "$port" "$SSHD_CONFIG"
}

# 测试SSH配置文件的语法
test_config() {
    info "正在测试SSH配置文件语法..."
    sshd -t
    return $?
}

# 配置SELinux，允许新端口
configure_selinux() {
    if command -v semanage &>/dev/null && command -v getenforce &>/dev/null && [[ "$(getenforce)" != "Disabled" ]]; then
        info "检测到 SELinux 正在运行。"
        if ! semanage port -l | grep ssh_port_t | grep -q "\btcp\b\s*$port\b"; then
            info "正在为新端口 $port 配置 SELinux 上下文..."
            semanage port -a -t ssh_port_t -p tcp "$port"
            if [ $? -eq 0 ]; then
                info "SELinux 端口上下文已成功添加。"
            else
                warn "配置 SELinux 端口上下文失败。如果 SSH 无法启动，这可能是原因。"
                warn "您可以尝试手动运行: semanage port -a -t ssh_port_t -p tcp $port"
            fi
        else
            info "SELinux 端口 $port 上下文已存在，无需操作。"
        fi
    fi
}


# 配置防火墙
configure_firewall() {
    if command -v firewall-cmd &>/dev/null && systemctl is-active --quiet firewalld; then
        info "检测到 firewalld 正在运行。"
        read -p "是否要为端口 $port 添加入站规则? (y/n): " choice
        if [[ "$choice" =~ ^[Yy]$ ]]; then
            firewall-cmd --permanent --add-port=${port}/tcp
            firewall-cmd --reload
            info "firewalld 已为端口 $port 开放。"
        fi
    elif command -v ufw &>/dev/null && ufw status | grep -q "Status: active"; then
        info "检测到 ufw 正在运行。"
        read -p "是否要为端口 $port 添加入站规则? (y/n): " choice
        if [[ "$choice" =~ ^[Yy]$ ]]; then
            ufw allow ${port}/tcp
            info "ufw 已为端口 $port 开放。"
        fi
    elif command -v iptables &>/dev/null; then
        info "检测到 iptables。"
        read -p "是否要为端口 $port 添加入站规则? (y/n): " choice
        if [[ "$choice" =~ ^[Yy]$ ]]; then
            iptables -I INPUT 1 -p tcp --dport ${port} -j ACCEPT
            info "iptables 规则已临时插入。"
            warn "请注意：iptables 规则在重启后可能会失效，您需要手动配置持久化（例如使用 iptables-persistent）。"
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
    
    # 在修改任何配置前，先调用新增的函数检查并修复主机密钥问题
    generate_ssh_host_keys_if_missing
    
    get_user_input
    
    local original_config
    original_config=$(cat "$SSHD_CONFIG")
    backup_config
    apply_config_changes
    
    if ! test_config; then
        warn "SSH配置文件语法错误！操作已中止，正在恢复原始配置文件..."
        printf "%s" "$original_config" > "$SSHD_CONFIG"
        error "已恢复原始配置，系统未做任何更改。"
    fi
    info "配置文件语法正确。"
    
    # 在重启服务前，处理SELinux和防火墙
    configure_selinux
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
