#!/bin/bash

set -o errexit
set -o nounset
set -o pipefail

# --- 全局变量和颜色定义 ---
readonly COLOR_GREEN='\033[0;32m'
readonly COLOR_RED='\033[0;31m'
readonly COLOR_YELLOW='\033[1;33m'
readonly COLOR_CYAN='\033[0;36m'
readonly COLOR_NC='\033[0m'

OS_ID=""
OS_VER=""
PKG_MANAGER=""
INSTALL_CMD=""
UPDATE_CMD=""
DEV_TOOLS_PKG=""

# --- 核心函数 ---
msg_info() { echo -e "${COLOR_CYAN}[*] $1${COLOR_NC}"; }
msg_ok() { echo -e "${COLOR_GREEN}[+] $1${COLOR_NC}"; }
msg_error() { echo -e "${COLOR_RED}[!] 错误: $1${COLOR_NC}" >&2; }
msg_warn() { echo -e "${COLOR_YELLOW}[-] 警告: $1${COLOR_NC}"; }

press_any_key() {
    echo ""
    read -n 1 -s -r -p "按任意键返回..."
}

check_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        msg_error "此脚本需要 root 权限，请使用 'sudo' 运行。"
        exit 1
    fi
}

detect_os_and_pkg_manager() {
    msg_info "正在检测操作系统和包管理器..."
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS_ID=$ID
        OS_VER=$VERSION_ID
    else
        msg_error "无法检测到操作系统，/etc/os-release 文件不存在。"
        exit 1
    fi

    case "$OS_ID" in
        ubuntu|debian)
            PKG_MANAGER="apt"
            UPDATE_CMD="apt-get update -y"
            INSTALL_CMD="apt-get install -y"
            DEV_TOOLS_PKG="build-essential"
            ;;
        centos|rhel|almalinux|rocky)
            PKG_MANAGER="yum"
            if command -v dnf &>/dev/null; then PKG_MANAGER="dnf"; fi
            UPDATE_CMD="$PKG_MANAGER update -y"
            INSTALL_CMD="$PKG_MANAGER install -y"
            DEV_TOOLS_PKG="@\"Development Tools\""
            ;;
        fedora)
            PKG_MANAGER="dnf"
            UPDATE_CMD="dnf update -y"
            INSTALL_CMD="dnf install -y"
            DEV_TOOLS_PKG="@\"Development Tools\""
            ;;
        arch)
            PKG_MANAGER="pacman"
            UPDATE_CMD="pacman -Syu --noconfirm"
            INSTALL_CMD="pacman -S --noconfirm"
            DEV_TOOLS_PKG="base-devel"
            ;;
        *)
            msg_error "不支持的操作系统: $OS_ID"
            exit 1
            ;;
    esac
    msg_ok "检测完成: 系统=$OS_ID, 包管理器=$PKG_MANAGER"
}

# --- BBR 管理 ---
check_bbr_status() {
    local kernel_version
    kernel_version=$(uname -r | cut -d'.' -f1-2)
    if [[ $(echo "$kernel_version < 4.9" | bc) -eq 1 ]]; then
        msg_error "内核版本 ($kernel_version) 过低, BBR 需要 4.9+ 内核。"
        return 1
    fi

    local bbr_in_sysctl
    bbr_in_sysctl=$(sysctl net.ipv4.tcp_congestion_control | awk '{print $3}')
    local bbr_loaded
    if lsmod | grep -q "tcp_bbr"; then
        bbr_loaded="yes"
    else
        bbr_loaded="no"
    fi

    msg_info "--- BBR 状态检查 ---"
    if [[ "$bbr_in_sysctl" == "bbr" && "$bbr_loaded" == "yes" ]]; then
        msg_ok "BBR 已成功启用。"
    else
        msg_warn "BBR 未启用或未完全启用。"
        echo "  - sysctl拥塞控制算法: $bbr_in_sysctl (应为 bbr)"
        echo "  - 内核模块(lsmod)已加载: $bbr_loaded (应为 yes)"
    fi
    echo "----------------------"
}

enable_bbr() {
    msg_info "正在启用 BBR..."
    if ! grep -q "net.core.default_qdisc=fq" /etc/sysctl.conf; then
        echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
    fi
    if ! grep -q "net.ipv4.tcp_congestion_control=bbr" /etc/sysctl.conf; then
        echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
    fi
    sysctl -p >/dev/null 2>&1
    msg_ok "BBR 配置已写入 /etc/sysctl.conf 并加载。"
    check_bbr_status
}

disable_bbr() {
    msg_info "正在禁用 BBR..."
    sed -i '/net.core.default_qdisc=fq/d' /etc/sysctl.conf
    sed -i '/net.ipv4.tcp_congestion_control=bbr/d' /etc/sysctl.conf
    sysctl -p >/dev/null 2>&1
    msg_ok "BBR 配置已从 /etc/sysctl.conf 移除并加载。"
    msg_warn "建议重启系统以确保网络完全恢复默认状态。"
}

manage_bbr() {
    while true; do
        clear
        echo "=== BBR 管理菜单 ==="
        echo "1) 启用 BBR"
        echo "2) 禁用 BBR"
        echo "3) 检查 BBR 状态"
        echo "0) 返回主菜单"
        read -p "请输入选项: " choice

        case "$choice" in
            1) enable_bbr ;;
            2) disable_bbr ;;
            3) check_bbr_status ;;
            0) break ;;
            *) msg_error "无效选项" ;;
        esac
        press_any_key
    done
}

# --- 内核管理 ---
install_ubuntu_mainline_kernel() {
    msg_info "正在使用 'ubuntu-mainline-kernel.sh' 脚本安装最新主线内核..."
    local script_path="/usr/local/bin/ubuntu-mainline-kernel.sh"
    if ! command -v "$script_path" &>/dev/null; then
        wget -qO "$script_path" https://raw.githubusercontent.com/pimlie/ubuntu-mainline-kernel.sh/master/ubuntu-mainline-kernel.sh
        chmod +x "$script_path"
    fi
    "$script_path" -i
    msg_ok "内核安装脚本执行完毕。请检查输出并重启系统以使用新内核。"
}

install_elrepo_kernel() {
    local repo_url="https://www.elrepo.org/elrepo-release-${OS_VER:0:1}.el${OS_VER:0:1}.elrepo.noarch.rpm"
    msg_info "正在为 CentOS/RHEL 系列安装 ELRepo..."
    rpm --import https://www.elrepo.org/RPM-GPG-KEY-elrepo.org
    $INSTALL_CMD "$repo_url"

    read -p "要安装最新主线内核(ml)还是长期支持内核(lt)? [ml/lt]: " kernel_type
    if [[ "$kernel_type" == "ml" ]]; then
        $INSTALL_CMD --enablerepo=elrepo-kernel kernel-ml
    elif [[ "$kernel_type" == "lt" ]]; then
        $INSTALL_CMD --enablerepo=elrepo-kernel kernel-lt
    else
        msg_error "无效的选择。"
        return
    fi
    msg_ok "内核安装完成。请重启系统并从GRUB菜单中选择新内核。"
}

manage_kernel() {
     while true; do
        clear
        echo "=== 内核管理菜单 ==="
        echo "当前内核: $(uname -r)"
        echo "----------------------"
        if [[ "$OS_ID" == "ubuntu" || "$OS_ID" == "debian" ]]; then
            echo "1) 安装最新主线内核 (通过 ubuntu-mainline-kernel.sh)"
        elif [[ "$OS_ID" == "centos" || "$OS_ID" == "rhel" || "$OS_ID" == "almalinux" || "$OS_ID" == "rocky" ]]; then
            echo "1) 安装 ELRepo 最新内核 (ml/lt)"
        else
            msg_warn "当前系统 ($OS_ID) 的内核自动安装暂不支持。"
        fi
        echo "0) 返回主菜单"
        read -p "请输入选项: " choice

        case "$choice" in
            1)
                if [[ "$OS_ID" == "ubuntu" || "$OS_ID" == "debian" ]]; then
                    install_ubuntu_mainline_kernel
                elif [[ "$OS_ID" == "centos" || "$OS_ID" == "rhel" || "$OS_ID" == "almalinux" || "$OS_ID" == "rocky" ]]; then
                    install_elrepo_kernel
                fi
                ;;
            0) break ;;
            *) msg_error "无效选项" ;;
        esac
        press_any_key
    done
}

# --- 软件包管理 ---
install_packages() {
    local pkgs_to_install="$1"
    msg_info "准备安装: $pkgs_to_install"
    read -p "是否继续? (Y/n): " confirm
    if [[ "$confirm" =~ ^[nN]$ ]]; then
        msg_warn "安装已取消。"
        return
    fi
    eval "$UPDATE_CMD"
    eval "$INSTALL_CMD $pkgs_to_install"
    msg_ok "软件包安装完成。"
}

manage_packages() {
    local base_pkgs="wget curl sudo nano unzip zip tar gzip bzip2 xz-utils screen tmux htop net-tools git"
    local network_pkgs="nmap netcat tcpdump iftop"

    while true; do
        clear
        echo "=== 软件包管理菜单 ==="
        echo "1) 安装基础包"
        echo "   ($base_pkgs)"
        echo "2) 安装开发工具"
        echo "   ($DEV_TOOLS_PKG)"
        echo "3) 安装网络工具"
        echo "   ($network_pkgs)"
        echo "0) 返回主菜单"
        read -p "请输入选项: " choice

        case "$choice" in
            1) install_packages "$base_pkgs" ;;
            2) install_packages "$DEV_TOOLS_PKG" ;;
            3) install_packages "$network_pkgs" ;;
            0) break ;;
            *) msg_error "无效选项" ;;
        esac
        press_any_key
    done
}


# --- 主菜单和执行 ---
main() {
    check_root
    detect_os_and_pkg_manager

    while true; do
        clear
        echo -e "${COLOR_GREEN}========================================="
        echo -e "        Linux 系统优化脚本 v1.0        "
        echo -e "=========================================${COLOR_NC}"
        echo "  系统: ${OS_ID} ${OS_VER}"
        echo "  内核: $(uname -r)"
        echo "-----------------------------------------"
        echo "  1) 软件包管理"
        echo "  2) 内核管理"
        echo "  3) BBR 管理"
        echo -e "  ${COLOR_RED}0) 退出脚本${COLOR_NC}"
        echo -e "${COLOR_GREEN}=========================================${COLOR_NC}"
        read -p "请输入您的选择: " main_choice

        case "$main_choice" in
            1) manage_packages ;;
            2) manage_kernel ;;
            3) manage_bbr ;;
            0) msg_ok "感谢使用，再见！"; exit 0 ;;
            *) msg_error "无效的选择 '$main_choice'，请重新输入。" ;;
        esac
        press_any_key
    done
}

main
