#!/bin/bash

set -o errexit
set -o nounset
set -o pipefail

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

update_and_cleanup_kernel() {
    msg_info "开始内核更新和清理流程..."
    read -p "此操作将更新内核，移除旧版本并要求重启，是否继续? (Y/n): " confirm
    if [[ "$confirm" =~ ^[nN]$ ]]; then
        msg_warn "操作已取消。"
        return
    fi

    msg_info "步骤 1/4: 更新软件包列表..."
    eval "$UPDATE_CMD"

    msg_info "步骤 2/4: 安装最新的内核包..."
    case "$OS_ID" in
        ubuntu|debian)
            eval "$INSTALL_CMD linux-generic"
            ;;
        centos|rhel|almalinux|rocky|fedora)
            eval "$PKG_MANAGER update -y kernel"
            ;;
        arch)
            pacman -Syu --noconfirm
            ;;
    esac
    msg_ok "内核更新包安装完成。"

    msg_info "步骤 3/4: 自动移除不再需要的旧内核..."
    case "$OS_ID" in
        ubuntu|debian)
            if apt-get autoremove --purge -y; then
                msg_ok "旧内核清理完成。"
            else
                msg_error "自动移除旧内核失败。"
            fi
            ;;
        centos|rhel|almalinux|rocky)
            if command -v dnf &>/dev/null; then
                local old_kernels
                old_kernels=$(dnf repoquery --installonly --latest-limit=-1 -q)
                if [[ -n "$old_kernels" ]]; then
                    if dnf remove -y $old_kernels; then
                        msg_ok "旧内核清理完成。"
                    else
                        msg_error "使用 dnf 移除旧内核失败。"
                    fi
                else
                    msg_info "没有找到可移除的旧内核。"
                fi
            else
                if ! command -v package-cleanup &>/dev/null; then
                    msg_info "正在安装 yum-utils 以使用 package-cleanup..."
                    yum install -y yum-utils
                fi
                if package-cleanup --oldkernels --count=1 -y; then
                    msg_ok "旧内核清理完成。"
                else
                    msg_error "使用 package-cleanup 移除旧内核失败。"
                fi
            fi
            ;;
        arch)
            msg_info "Arch Linux 在系统更新时处理内核，自动清理风险较高，建议手动管理。"
            ;;
    esac

    msg_info "步骤 4/4: 重启系统..."
    msg_warn "所有操作已完成。系统需要重启以加载新内核。"
    read -p "是否立即重启? (Y/n): " reboot_confirm
    if [[ ! "$reboot_confirm" =~ ^[nN]$ ]]; then
        msg_info "正在重启系统..."
        reboot
    else
        msg_warn "请记得稍后手动重启以应用新内核。"
    fi
}

manage_kernel() {
    while true; do
        clear
        echo "=== 内核管理菜单 ==="
        echo "当前内核: $(uname -r)"
        echo "----------------------------------------------------------"
        echo "1) 从官方源更新内核 (仅安装)"
        echo -e "2) ${COLOR_YELLOW}更新内核并清理旧版本 (推荐并重启)${COLOR_NC}"
        echo "0) 返回主菜单"

        read -p "请输入选项: " choice

        case "$choice" in
            1)
                msg_info "即将执行标准的内核更新流程..."
                read -p "此操作会连接官方软件源并安装/更新内核，是否继续? (Y/n): " confirm
                if [[ "$confirm" =~ ^[nN]$ ]]; then
                    msg_warn "操作已取消。"
                else
                    eval "$UPDATE_CMD"
                    case "$OS_ID" in
                        ubuntu|debian)
                            msg_info "正在为 Debian/Ubuntu 执行: $INSTALL_CMD linux-generic"
                            eval "$INSTALL_CMD linux-generic"
                            ;;
                        centos|rhel|almalinux|rocky|fedora)
                            msg_info "正在为 RHEL/CentOS/Fedora 执行: $PKG_MANAGER update -y kernel"
                            eval "$PKG_MANAGER update -y kernel"
                            ;;
                        arch)
                            msg_info "Arch Linux 通过完整系统更新来更新内核..."
                            msg_info "正在执行: pacman -Syu --noconfirm"
                            pacman -Syu --noconfirm
                            ;;
                        *)
                            msg_error "当前系统 ($OS_ID) 没有预设的统一更新命令。"
                            press_any_key
                            continue
                            ;;
                    esac
                    msg_ok "内核更新操作已完成。如果内核有版本变动，请重启系统以生效。"
                fi
                press_any_key
                ;;
            2)
                update_and_cleanup_kernel
                break 
                ;;
            0)
                break
                ;;
            *)
                msg_error "无效选项"
                press_any_key
                ;;
        esac
    done
}

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

main() {
    check_root
    detect_os_and_pkg_manager

    while true; do
        clear
        echo -e "${COLOR_GREEN}========================================="
        echo -e "        Linux 系统优化脚本 v1.4        "
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
    done
}

main
