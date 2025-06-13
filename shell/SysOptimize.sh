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

update_grub_config() {
    msg_info "正在更新 GRUB 引导配置..."
    if command -v update-grub &>/dev/null; then
        update-grub
        msg_ok "GRUB (update-grub) 更新成功。"
    elif command -v grub2-mkconfig &>/dev/null; then
        if [ -f /boot/grub2/grub.cfg ]; then
            grub2-mkconfig -o /boot/grub2/grub.cfg
            msg_ok "GRUB (grub2-mkconfig) 更新成功。"
        elif [ -f /boot/efi/EFI/$(echo "$OS_ID" | tr '[:upper:]' '[:lower:]')/grub.cfg ]; then
             grub2-mkconfig -o /boot/efi/EFI/$(echo "$OS_ID" | tr '[:upper:]' '[:lower:]')/grub.cfg
             msg_ok "GRUB (grub2-mkconfig) 更新成功。"
        else
            msg_warn "找到了 grub2-mkconfig, 但未找到标准的 grub.cfg 路径，请手动更新。"
        fi
    else
        msg_warn "未找到 update-grub 或 grub2-mkconfig, 请在需要时手动更新引导配置。"
    fi
}

delete_kernel_manually() {
    msg_info "正在扫描已安装的内核..."
    
    local kernels_array=()
    local current_kernel_pkg=""
    local packages_to_delete=()

    case "$OS_ID" in
        ubuntu|debian)
            mapfile -t kernels_array < <(dpkg-query -W -f='${Package}\n' 'linux-image-[0-9]*' | grep -v 'generic$')
            current_kernel_pkg="linux-image-$(uname -r)"
            ;;
        centos|rhel|almalinux|rocky|fedora)
            mapfile -t kernels_array < <(rpm -q kernel)
            current_kernel_pkg="kernel-$(uname -r)"
            ;;
        arch)
            msg_warn "在 Arch Linux 上, 内核通常通过 pacman 直接管理 (例如: 'sudo pacman -R linux-lts')。"
            msg_warn "此脚本不提供自动删除功能以避免风险。请手动操作。"
            return
            ;;
        *)
            msg_error "当前操作系统 ($OS_ID) 不支持手动内核删除功能。"
            return
            ;;
    esac

    if [ ${#kernels_array[@]} -eq 0 ]; then
        msg_error "未找到任何可管理的内核包。"
        return
    fi

    echo "发现以下已安装的内核:"
    local i=1
    local display_kernels=()
    for pkg in "${kernels_array[@]}"; do
        local display_text="$pkg"
        if [[ "$pkg" == "$current_kernel_pkg" ]]; then
            display_text="${COLOR_GREEN}${pkg} (当前正在运行)${COLOR_NC}"
        fi
        echo -e "  $i) $display_text"
        display_kernels+=("$pkg")
        ((i++))
    done
    
    echo "----------------------------------------------------------"
    read -p "请输入要删除的内核编号 (多个请用空格隔开)，或按 Enter 取消: " selection

    if [[ -z "$selection" ]]; then
        msg_info "操作已取消。"
        return
    fi

    for index in $selection; do
        if ! [[ "$index" =~ ^[1-9][0-9]*$ && "$index" -le "${#kernels_array[@]}" ]]; then
            msg_warn "无效的编号: $index, 已跳过。"
            continue
        fi

        local selected_pkg="${kernels_array[$((index-1))]}"
        if [[ "$selected_pkg" == "$current_kernel_pkg" ]]; then
            msg_error "安全保护：无法删除当前正在运行的内核 ($selected_pkg)，已跳过。"
            continue
        fi
        packages_to_delete+=("$selected_pkg")
    done

    if [ ${#packages_to_delete[@]} -eq 0 ]; then
        msg_info "没有选择任何有效的内核进行删除。"
        return
    fi

    msg_warn "即将永久删除以下内核包及其关联组件:"
    for pkg in "${packages_to_delete[@]}"; do
        echo "  - $pkg"
    done
    read -p "请再次确认是否继续? (y/N): " confirm

    if [[ ! "$confirm" =~ ^[yY]$ ]]; then
        msg_info "操作已由用户取消。"
        return
    fi
    
    local full_package_list_to_delete_str
    case "$OS_ID" in
        ubuntu|debian)
            local temp_list=()
            for pkg in "${packages_to_delete[@]}"; do
                local version_string
                version_string=$(echo "$pkg" | sed 's/linux-image-//')
                temp_list+=( $(dpkg-query -W -f='${Package}\n' "linux-*-${version_string}" 2>/dev/null) )
            done
            full_package_list_to_delete_str=$(printf "%s\n" "${temp_list[@]}" | sort -u | tr '\n' ' ')
            ;;
        centos|rhel|almalinux|rocky|fedora)
            full_package_list_to_delete_str=$(printf "%s " "${packages_to_delete[@]}")
            ;;
    esac

    msg_info "正在执行删除命令..."
    if eval "$PKG_MANAGER remove -y $full_package_list_to_delete_str"; then
        msg_ok "选定的内核包已成功删除。"
    else
        msg_error "删除内核时出错。"
        return
    fi

    update_grub_config
    
    msg_warn "操作完成。建议重启系统以使更改生效。"
}


manage_kernel() {
    while true; do
        clear
        echo "=== 内核管理菜单 ==="
        echo "当前内核: $(uname -r)"
        echo "----------------------------------------------------------"
        echo "1) 从官方源更新内核 (仅安装)"
        echo -e "2) ${COLOR_YELLOW}手动清理已安装的内核 (推荐)${COLOR_NC}"
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
                delete_kernel_manually
                press_any_key
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
        echo -e "     Linux 系统优化脚本 v1.7     "
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
