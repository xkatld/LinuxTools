#!/bin/bash
#
# =================================================================
# Script Name:    Debian/Ubuntu Updater & Cleaner
# Description:    一个为 Debian 和 Ubuntu 设计的自适应系统更新脚本，
#                 并在更新后提供清晰的清理指导。
# =================================================================

# --- 安全设置 ---
set -o errexit
set -o nounset
set -o pipefail

# --- 颜色定义 ---
readonly COLOR_GREEN='\033[0;32m'
readonly COLOR_RED='\033[0;31m'
readonly COLOR_YELLOW='\033[1;33m'
readonly COLOR_CYAN='\033[0;36m'
readonly COLOR_NC='\033[0m' # No Color

# --- 消息函数 ---
msg_info() { echo -e "${COLOR_CYAN}[*] $1${COLOR_NC}"; }
msg_ok() { echo -e "${COLOR_GREEN}[+] $1${COLOR_NC}"; }
msg_error() { echo -e "${COLOR_RED}[!] 错误: $1${COLOR_NC}" >&2; }
msg_warn() { echo -e "${COLOR_YELLOW}[-] 警告: $1${COLOR_NC}"; }

# --- 核心功能函数 ---

# 1. 检查是否以 root 权限运行
check_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        msg_error "此脚本需要 root 权限，请使用 'sudo bash $0' 运行。"
        exit 1
    fi
}

# 2. 检测操作系统是否为 Debian 或 Ubuntu
check_distro() {
    if [ -f /etc/os-release ]; then
        # shellcheck source=/dev/null
        . /etc/os-release
        if [[ "$ID" == "debian" || "$ID" == "ubuntu" ]]; then
            msg_ok "检测到系统为: $PRETTY_NAME"
        else
            msg_error "此脚本仅为 Debian 和 Ubuntu 设计。检测到您的系统是 $ID，脚本将退出。"
            exit 1
        fi
    else
        msg_error "无法检测到操作系统，/etc/os-release 文件不存在。"
        exit 1
    fi
}

# 3. 执行系统更新
run_upgrade() {
    msg_info "--- 第1步: 正在更新软件包列表 (apt update) ---"
    apt-get update

    msg_info "\n--- 第2步: 正在升级已安装的软件包 (apt upgrade) ---"
    apt-get upgrade -y

    msg_info "\n--- 第3步: 正在执行发行版升级 (apt dist-upgrade) ---"
    msg_warn "此步骤可能会安装或删除一些包以解决依赖关系变更。"
    apt-get dist-upgrade -y

    msg_ok "\n========================================================"
    msg_ok "恭喜！系统已成功更新到最新版本。"
    msg_ok "========================================================"
}

# 4. 显示清理命令
show_cleanup_instructions() {
    echo -e "\n"
    msg_info "--- 系统清理建议 ---"
    msg_warn "为了保持系统纯净，建议您运行以下命令进行清理："
    echo -e "\n  ${COLOR_YELLOW}1. 自动移除不再需要的依赖包:${COLOR_NC}"
    echo -e "     ${COLOR_GREEN}sudo apt autoremove${COLOR_NC}"
    echo -e "\n  ${COLOR_YELLOW}2. 清理已下载的软件包缓存:${COLOR_NC}"
    echo -e "     ${COLOR_GREEN}sudo apt clean${COLOR_NC}"
    echo -e "\n--------------------------------------------------------"
}


# 5. （可选）清理旧内核
cleanup_old_kernels() {
    msg_info "正在扫描已安装的内核..."

    # 使用 dpkg-query 查找所有已安装的内核包，但不包括当前正在运行的内核元数据包
    local current_kernel
    current_kernel=$(uname -r)
    local installed_kernels
    installed_kernels=($(dpkg-query -W -f='${Package}\n' 'linux-image-[0-9]*' | grep -v "${current_kernel}"))

    if [ ${#installed_kernels[@]} -eq 0 ]; then
        msg_ok "未发现可供清理的旧内核。"
        return
    fi

    msg_warn "发现以下可被移除的旧内核:"
    for kernel in "${installed_kernels[@]}"; do
        echo "  - $kernel"
    done

    echo ""
    read -p "是否要自动移除这些旧内核? (y/N): " confirm
    if [[ ! "$confirm" =~ ^[yY]$ ]]; then
        msg_info "操作已取消。"
        return
    fi

    msg_info "正在移除旧内核，这可能需要一些时间..."
    # 使用 xargs 将列表传递给 apt-get purge
    printf "%s\n" "${installed_kernels[@]}" | xargs sudo apt-get purge -y
    
    msg_ok "旧内核清理完毕。"

    msg_info "正在更新 GRUB 引导配置..."
    update-grub
    msg_ok "GRUB 配置更新成功。"
}


# --- 主函数 ---
main() {
    clear
    msg_info "欢迎使用 Debian/Ubuntu 系统更新与清理脚本。"
    echo "--------------------------------------------------------"
    
    check_root
    check_distro
    
    echo ""
    read -p "即将开始系统更新流程，是否继续? (Y/n): " confirm_start
    if [[ "$confirm_start" =~ ^[nN]$ ]]; then
        msg_info "操作已由用户取消。"
        exit 0
    fi
    
    run_upgrade
    show_cleanup_instructions
    
    read -p "是否需要立即执行可选的【旧内核清理】? (y/N): " confirm_kernel_cleanup
    if [[ "$confirm_kernel_cleanup" =~ ^[yY]$ ]]; then
        cleanup_old_kernels
    fi

    msg_ok "\n所有操作已完成。建议重启系统以应用所有更新，特别是内核更新。"
}

# --- 脚本执行入口 ---
main