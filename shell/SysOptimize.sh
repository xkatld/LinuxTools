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

# --- 内核管理 (v1.1 修订版) ---
manage_kernel() {
    while true; do
        clear
        echo "=== 内核管理菜单 (官方源策略) ==="
        echo "当前内核: $(uname -r)"
        msg_info "策略: 提供官方软件源中稳定、受支持的最新内核版本。"
        echo "-----------------------------------------------------"
        
        local kernel_option_available=false
        case "$OS_ID" in
            ubuntu)
                echo "1) 安装/更新 HWE 内核 (官方推荐的、用于支持新硬件的较新内核)"
                kernel_option_available=true
                ;;
            debian)
                echo "1) 安装/更新 backports 内核 (官方的较新内核)"
                kernel_option_available=true
                ;;
            centos|rhel|almalinux|rocky)
                echo "1) 更新到当前分支的最新内核版本"
                kernel_option_available=true
                ;;
            arch|fedora)
                msg_warn "您使用的是滚动发行版，通过常规系统更新即可获取最新内核。"
                ;;
            *)
                msg_error "您的系统 ($OS_ID) 暂无简化的内核更新选项。"
                ;;
        esac
        echo "0) 返回主菜单"
        
        if ! $kernel_option_available; then
            read -p "按0返回: " choice
            [[ "$choice" == "0" ]] && break
            continue
        fi

        read -p "请输入选项: " choice
        case "$choice" in
            1)
                case "$OS_ID" in
                    ubuntu)
                        msg_info "即将安装 Ubuntu Hardware Enablement (HWE) 内核..."
                        read -p "HWE内核由官方提供，用于支持较新的硬件，是否继续? (Y/n): " confirm
                        if [[ "$confirm" =~ ^[nN]$ ]]; then msg_warn "操作已取消。"; else
                            $UPDATE_CMD
                            local hwe_pkg="linux-generic-hwe-$(lsb_release -rs)"
                            msg_info "正在执行: $INSTALL_CMD $hwe_pkg"
                            $INSTALL_CMD "$hwe_pkg"
                            msg_ok "HWE 内核安装/更新完成，请重启系统以生效。"
                        fi
                        ;;
                    debian)
                        msg_info "即将安装 Debian backports 内核..."
                        read -p "Backports 内核由官方提供，版本较新，是否继续? (Y/n): " confirm
                        if [[ "$confirm" =~ ^[nN]$ ]]; then msg_warn "操作已取消。"; else
                            local CODENAME=$(. /etc/os-release; echo $VERSION_CODENAME)
                            echo "deb http://deb.debian.org/debian ${CODENAME}-backports main" > /etc/apt/sources.list.d/backports.list
                            $UPDATE_CMD
                            msg_info "正在从 backports 安装内核..."
                            $INSTALL_CMD -t ${CODENAME}-backports linux-image-amd64 linux-headers-amd64
                            msg_ok "Backports 内核安装/更新完成，请重启系统以生效。"
                        fi
                        ;;
                    centos|rhel|almalinux|rocky)
                        msg_info "即将从官方源更新内核..."
                        read -p "此操作会更新到当前系统分支最新的稳定内核，是否继续? (Y/y): " confirm
                        if [[ "$confirm" =~ ^[nN]$ ]]; then msg_warn "操作已取消。"; else
                            msg_info "正在执行: $PKG_MANAGER update kernel"
                            $PKG_MANAGER update -y kernel
                            msg_ok "内核更新完成，请重启系统以生效。"
                        fi
                        ;;
                esac
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
        echo -e "        Linux 系统优化脚本 v1.1        "
        echo -e "=========================================${COLOR_NC}"
        echo "  系统: ${OS_ID} ${OS_VER}"
        echo "  内核: $(uname -r)"
        echo "-----------------------------------------"
        echo "  1) 软件包管理"
        echo "  2) 内核管理 (官方源策略)"
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
