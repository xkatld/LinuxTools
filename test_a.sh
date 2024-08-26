#!/bin/bash

# 检测包管理器
if command -v apt &> /dev/null; then
    PKG_MANAGER="apt"
    INSTALL_CMD="apt install -y"
    UPDATE_CMD="apt update -y && apt upgrade -y"
elif command -v yum &> /dev/null; then
    PKG_MANAGER="yum"
    INSTALL_CMD="yum install -y"
    UPDATE_CMD="yum update -y"
elif command -v dnf &> /dev/null; then
    PKG_MANAGER="dnf"
    INSTALL_CMD="dnf install -y"
    UPDATE_CMD="dnf update -y"
elif command -v zypper &> /dev/null; then
    PKG_MANAGER="zypper"
    INSTALL_CMD="zypper install -y"
    UPDATE_CMD="zypper update -y"
elif command -v pacman &> /dev/null; then
    PKG_MANAGER="pacman"
    INSTALL_CMD="pacman -S --noconfirm"
    UPDATE_CMD="pacman -Syu --noconfirm"
else
    echo "无法检测到支持的包管理器。"
    exit 1
fi

# 定义软件包组
BASE_PACKAGES="wget curl sudo nano unzip zip tar gzip bzip2 xz screen tmux htop net-tools"
GITHUB_PACKAGES="git git-lfs"
PYTHON_PACKAGES="python3 python3-pip"
GO_PACKAGES="golang"
BUILD_PACKAGES="gcc g++ make autoconf automake libtool"
NETWORK_PACKAGES="nmap netcat tcpdump wireshark tshark iftop"

# 安装函数
install_packages() {
    echo "正在安装: $1"
    sudo $INSTALL_CMD $1
    if [ $? -ne 0 ]; then
        echo "安装失败，请检查错误信息。"
    else
        echo "安装成功。"
    fi
}

# 更新包列表
update_packages() {
    echo "正在更新系统..."
    sudo $UPDATE_CMD
}

# 主菜单
while true; do
    echo "请选择要安装的软件包组："
    echo "1) 基础包"
    echo "2) GitHub 相关"
    echo "3) Python3 相关"
    echo "4) Go 语言相关"
    echo "5) 编译依赖相关"
    echo "6) 网络工具相关"
    echo "7) 安装所有软件包"
    echo "8) 退出"
    read -p "请输入选项 (1-8): " choice

    case $choice in
        1) update_packages && install_packages "$BASE_PACKAGES" ;;
        2) install_packages "$GITHUB_PACKAGES" ;;
        3) install_packages "$PYTHON_PACKAGES" ;;
        4) install_packages "$GO_PACKAGES" ;;
        5) install_packages "$BUILD_PACKAGES" ;;
        6) install_packages "$NETWORK_PACKAGES" ;;
        7) 
            update_packages
            install_packages "$BASE_PACKAGES $GITHUB_PACKAGES $PYTHON_PACKAGES $GO_PACKAGES $BUILD_PACKAGES $NETWORK_PACKAGES"
            ;;
        8) 
            echo "退出脚本。"
            exit 0
            ;;
        *)
            echo "无效选项，请重新选择。"
            ;;
    esac

    echo ""
done
