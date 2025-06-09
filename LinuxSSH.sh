#!/bin/bash

if [[ $EUID -ne 0 ]]; then
   echo "此脚本必须以root权限运行"
   exit 1
fi

install_sshd() {
    local PKG_MANAGER=""
    local INSTALL_CMD=""
    local UPDATE_CMD=""
    local SSH_PACKAGE="openssh-server"

    if command -v apt-get &>/dev/null; then
        PKG_MANAGER="apt"
        INSTALL_CMD="apt-get install -y"
        UPDATE_CMD="apt-get update"
    elif command -v dnf &>/dev/null; then
        PKG_MANAGER="dnf"
        INSTALL_CMD="dnf install -y"
    elif command -v yum &>/dev/null; then
        PKG_MANAGER="yum"
        INSTALL_CMD="yum install -y"
    elif command -v pacman &>/dev/null; then
        PKG_MANAGER="pacman"
        INSTALL_CMD="pacman -S --noconfirm"
        SSH_PACKAGE="openssh"
    elif command -v zypper &>/dev/null; then
        PKG_MANAGER="zypper"
        INSTALL_CMD="zypper install -y"
        SSH_PACKAGE="openssh"
    elif command -v apk &>/dev/null; then
        PKG_MANAGER="apk"
        INSTALL_CMD="apk add"
        UPDATE_CMD="apk update"
        SSH_PACKAGE="openssh"
    elif command -v opkg &>/dev/null; then
        PKG_MANAGER="opkg"
        INSTALL_CMD="opkg install"
        UPDATE_CMD="opkg update"
    else
        echo "无法检测到支持的包管理器。"
        echo "请手动安装 OpenSSH server 后，再运行此脚本进行配置。"
        return 1
    fi

    if ! command -v sshd &>/dev/null; then
        echo "检测到包管理器: $PKG_MANAGER"
        echo "OpenSSH server 未安装，正在安装..."
        if [ -n "$UPDATE_CMD" ]; then
            $UPDATE_CMD
        fi
        $INSTALL_CMD $SSH_PACKAGE
        if [ $? -ne 0 ]; then
            echo "OpenSSH server 安装失败。"
            exit 1
        fi
    else
        echo "OpenSSH server 已安装。"
    fi
    return 0
}

install_sshd
if [ $? -ne 0 ]; then
    read -p "您想在未安装sshd的情况下继续配置吗? (y/n): " continue_anyway
    if [[ "$continue_anyway" != "y" ]]; then
        exit 1
    fi
fi

read -s -p "请输入新的root密码: " CUSTOM_PASSWORD
echo
read -s -p "请再次输入新的root密码以确认: " CUSTOM_PASSWORD_CONFIRM
echo

if [ "$CUSTOM_PASSWORD" != "$CUSTOM_PASSWORD_CONFIRM" ]; then
    echo "密码不匹配，请重新运行脚本。"
    exit 1
fi

read -p "请输入新的SSH端口（例如：22）: " CUSTOM_PORT
echo

if ! [[ "$CUSTOM_PORT" =~ ^[0-9]+$ ]] || [ "$CUSTOM_PORT" -lt 1 ] || [ "$CUSTOM_PORT" -gt 65535 ]; then
    echo "错误：端口必须是1-65535之间的数字。"
    exit 1
fi

SSHD_CONFIG="/etc/ssh/sshd_config"

if [ ! -f "$SSHD_CONFIG" ]; then
    echo "错误: 找不到 SSH 配置文件: $SSHD_CONFIG"
    echo "请确保 OpenSSH server 已正确安装。"
    exit 1
fi

echo "root:$CUSTOM_PASSWORD" | chpasswd

sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin yes/' "$SSHD_CONFIG"
sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' "$SSHD_CONFIG"
sed -i "s/^#\?Port.*/Port $CUSTOM_PORT/" "$SSHD_CONFIG"

if ! grep -q "^Port " "$SSHD_CONFIG"; then
    echo "Port $CUSTOM_PORT" >> "$SSHD_CONFIG"
fi

echo "正在重启 SSH 服务..."
if command -v systemctl &>/dev/null; then
    systemctl restart sshd
elif command -v service &>/dev/null; then
    service sshd restart
else
    echo "无法自动重启SSH服务。请手动重启。"
fi

echo "Root密码和SSH端口已成功设置。"
echo "新的SSH端口是: $CUSTOM_PORT"
echo "请注意，允许root直接登录可能存在安全风险。"
