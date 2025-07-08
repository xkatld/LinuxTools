#!/bin/bash

set -o errexit
set -o pipefail

readonly COLOR_RED='\033[0;31m'
readonly COLOR_GREEN='\033[0;32m'
readonly COLOR_YELLOW='\033[1;33m'
readonly COLOR_BLUE='\033[0;34m'
readonly COLOR_NC='\033[0m'

SYSTEM_ARCH=""
DEBIAN_CODENAME=""
PVE_VERSION=""
HOSTNAME_FQDN=""
SERVER_IP=""
MIRROR_BASE=""
PVE_REPO_COMPONENT=""
PVE_GPG_KEY_URL=""

log_info() { printf "${COLOR_GREEN}[INFO]${COLOR_NC} %s\n" "$1"; }
log_warn() { printf "${COLOR_YELLOW}[WARN]${COLOR_NC} %s\n" "$1"; }
log_error() { printf "${COLOR_RED}[ERROR]${COLOR_NC} %s\n" "$1"; }
log_step() { printf "\n${COLOR_BLUE}>>> [步骤] %s${COLOR_NC}\n" "$1"; }

function cleanup_on_exit() {
    log_warn "脚本被中断或发生错误，正在退出..."
    exit 1
}

function check_prerequisites() {
    log_step "检查系统环境和依赖"

    if [[ $EUID -ne 0 ]]; then
        log_error "此脚本必须以 root 权限运行。请尝试使用 'sudo'。"
        exit 1
    fi

    local arch
    arch=$(uname -m)
    case "$arch" in
        aarch64|arm64)
            SYSTEM_ARCH="arm64"
            ;;
        x86_64|amd64)
            SYSTEM_ARCH="amd64"
            ;;
        *)
            log_error "不支持的系统架构: $arch"
            log_info "此脚本仅支持 amd64 (x86_64) 和 arm64 (aarch64)。"
            exit 1
            ;;
    esac
    log_info "检测到系统架构: ${SYSTEM_ARCH}"

    declare -A deps_map=(
        ["curl"]="curl"
        ["lsb_release"]="lsb-release"
    )
    local missing_pkgs=()

    for cmd in "${!deps_map[@]}"; do
        if ! command -v "$cmd" &>/dev/null; then
            missing_pkgs+=("${deps_map[$cmd]}")
        fi
    done

    if [[ ${#missing_pkgs[@]} -gt 0 ]]; then
        local missing_pkgs_str
        missing_pkgs_str=$(printf " %s" "${missing_pkgs[@]}")
        missing_pkgs_str=${missing_pkgs_str:1}

        log_error "缺少必要的软件包: ${missing_pkgs_str}"
        log_info "请尝试运行 'apt-get update && apt-get install -y ${missing_pkgs_str}' 来安装它们。"
        exit 1
    fi
    log_info "所有依赖项均已满足。"
}

function check_debian_version() {
    log_step "验证 Debian 版本"
    
    if [[ ! -f /etc/debian_version ]]; then
        log_error "未检测到 Debian 系统，此脚本无法继续。"
        exit 1
    fi
    
    DEBIAN_CODENAME=$(lsb_release -cs)

    case "$DEBIAN_CODENAME" in
        bullseye)
            PVE_VERSION="7"
            log_info "检测到 Debian 11 (Bullseye)，将准备安装 PVE $PVE_VERSION"
            ;;
        bookworm)
            PVE_VERSION="8"
            log_info "检测到 Debian 12 (Bookworm)，将准备安装 PVE $PVE_VERSION"
            ;;
        *)
            log_error "不支持的 Debian 版本: $DEBIAN_CODENAME (仅支持 bullseye 和 bookworm)"
            exit 1
            ;;
    esac
}

function configure_architecture_specifics() {
    log_step "根据架构 (${SYSTEM_ARCH}) 配置软件源"

    if [[ "$SYSTEM_ARCH" == "amd64" ]]; then
        log_info "为 AMD64 架构使用 Proxmox 官方软件源。"
        MIRROR_BASE="http://download.proxmox.com/debian/pve"
        PVE_REPO_COMPONENT="pve-no-subscription"
        PVE_GPG_KEY_URL="https://enterprise.proxmox.com/debian/proxmox-release-${DEBIAN_CODENAME}.gpg"
    else
        # 修正之处：为 ARM64 单独处理 URL，确保路径正确
        log_info "为 ARM64 架构选择第三方镜像源。"
        local choice
        local mirror_domain
        while true; do
            printf "请选择一个地理位置较近的镜像源以获得更快的速度：\n"
            printf "  1) 主源 (韩国)\n"
            printf "  2) 中国 (Lierfang)\n"
            printf "  3) 中国香港\n"
            printf "  4) 德国\n"
            read -p "请输入选项数字 (1-4): " choice
            
            case $choice in
                1) mirror_domain="https://mirrors.apqa.cn"; break ;;
                2) mirror_domain="https://mirrors.lierfang.com"; break ;;
                3) mirror_domain="https://hk.mirrors.apqa.cn"; break ;;
                4) mirror_domain="https://de.mirrors.apqa.cn"; break ;;
                *) log_warn "无效的选项，请输入 1 到 4 之间的数字。" ;;
            esac
        done
        # 分别、显式地构建软件源和GPG密钥的URL
        MIRROR_BASE="${mirror_domain}/proxmox/debian/pve"
        PVE_REPO_COMPONENT="port"
        PVE_GPG_KEY_URL="${mirror_domain}/proxmox/debian/pveport.gpg"
    fi
    log_info "软件源地址已设置为: ${MIRROR_BASE}"
    log_info "GPG密钥地址已设置为: ${PVE_GPG_KEY_URL}"
}

function configure_hostname() {
    log_step "配置主机名和 /etc/hosts 文件"
    
    local hostname domain
    while true; do
        read -p "请输入主机名 (例如: pve): " hostname
        if [[ -n "$hostname" ]]; then
            break
        else
            log_warn "主机名不能为空，请重新输入。"
        fi
    done

    while true; do
        read -p "请输入域名 (例如: local, home): " domain
        if [[ -n "$domain" ]]; then
            break
        else
            log_warn "域名不能为空，请重新输入。"
        fi
    done
    
    HOSTNAME_FQDN="${hostname}.${domain}"

    while true; do
        read -p "请输入服务器的静态 IP 地址 (例如: 192.168.1.10): " SERVER_IP
        if [[ -z "$SERVER_IP" ]]; then
            log_warn "IP 地址不能为空，请重新输入。"
            continue
        fi
        if [[ $SERVER_IP =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
            break
        else
            log_warn "无效的 IP 地址格式，请重新输入。"
        fi
    done

    log_info "配置预览："
    echo "  - 完整主机名 (FQDN): ${HOSTNAME_FQDN}"
    echo "  - IP 地址: ${SERVER_IP}"
    
    local confirm_hosts
    read -p "即将修改主机名并覆盖 /etc/hosts 文件，是否继续? (y/N): " confirm_hosts
    if [[ "${confirm_hosts,,}" != "y" ]]; then
        log_warn "操作已取消。"
        return 1
    fi

    hostnamectl set-hostname "$HOSTNAME_FQDN" --static
    log_info "主机名已设置为: $HOSTNAME_FQDN"

    local hosts_content
    hosts_content=$(cat <<EOF
127.0.0.1       localhost
::1             localhost ip6-localhost ip6-loopback
ff02::1         ip6-allnodes
ff02::2         ip6-allrouters
${SERVER_IP}    ${HOSTNAME_FQDN} ${hostname}
EOF
)
    echo "$hosts_content" > /etc/hosts.tmp && mv /etc/hosts.tmp /etc/hosts
    log_info "/etc/hosts 文件已成功更新。"
}

function backup_apt_config() {
    log_step "备份当前 APT 源配置"
    
    local backup_dir="/root/pve_install_backup_$(date +%Y%m%d_%H%M%S)"
    if mkdir -p "$backup_dir"; then
        log_info "备份目录已创建: $backup_dir"
    else
        log_error "无法创建备份目录，请检查权限。"
        return 1
    fi
    
    find /etc/apt/ -name "*.list" -exec cp {} "$backup_dir/" \;
    log_info "所有 .list 文件已备份。"
}

function run_installation() {
    log_step "开始安装 Proxmox VE"
    
    log_info "正在下载 Proxmox GPG 密钥..."
    local gpg_key_name
    gpg_key_name=$(basename "$PVE_GPG_KEY_URL")
    if ! curl -fsSL "${PVE_GPG_KEY_URL}" -o "/etc/apt/trusted.gpg.d/${gpg_key_name}"; then
        log_error "GPG 密钥下载失败。请检查网络连接或源地址是否可用。"
        exit 1
    fi
    chmod 644 "/etc/apt/trusted.gpg.d/${gpg_key_name}"
    log_info "GPG 密钥安装成功。"

    log_info "正在配置 Proxmox VE 的 APT 源..."
    echo "deb ${MIRROR_BASE} ${DEBIAN_CODENAME} ${PVE_REPO_COMPONENT}" > /etc/apt/sources.list.d/pve.list
    
    log_info "正在更新软件包列表 (apt-get update)..."
    if ! apt-get update; then
        log_error "软件包列表更新失败。请检查您的网络和 APT 配置。"
        exit 1
    fi
    
    log_info "正在安装 Proxmox VE 核心包... 这可能需要一些时间。"
    export DEBIAN_FRONTEND=noninteractive
    if ! apt-get install -y proxmox-ve postfix open-iscsi; then
        log_error "Proxmox VE 安装失败。请检查上面的错误信息以诊断问题。"
        exit 1
    fi

    log_info "Proxmox VE 核心组件安装成功！"
}

function show_completion_info() {
    local ip
    ip=$(hostname -I | awk '{print $1}')

    printf "\n============================================================\n"
    log_info "    Proxmox VE $PVE_VERSION 安装成功!    "
    printf "============================================================\n\n"
    
    log_info "请通过以下地址访问 Proxmox VE Web 管理界面:"
    printf "  ${COLOR_YELLOW}URL:      https://%s:8006/${COLOR_NC}\n" "${ip}"
    printf "  ${COLOR_YELLOW}用户名:   root${COLOR_NC}\n"
    printf "  ${COLOR_YELLOW}密码:     (您的系统 root 密码)${COLOR_NC}\n\n"
    
    log_warn "为了加载新的 Proxmox 内核，系统需要重启。"
    local reboot_confirm
    read -p "是否立即重启系统? (y/N): " reboot_confirm
    if [[ "${reboot_confirm,,}" == "y" ]]; then
        log_info "系统将在 5 秒后重启..."
        sleep 5
        reboot
    else
        log_warn "重启已取消。请在方便时手动运行 'reboot' 命令。"
    fi
}

function main() {
    trap cleanup_on_exit INT TERM
    
    echo "欢迎使用 Proxmox VE 通用安装脚本 (AMD64/ARM64)"

    check_prerequisites
    check_debian_version
    configure_architecture_specifics

    if ! configure_hostname; then
        log_error "主机名配置未完成，脚本终止。"
        exit 1
    fi
    
    printf "\n====================== 最终安装确认 ======================\n"
    log_info "系统环境检查完成，配置如下："
    printf "  - 系统架构:        %s\n" "$SYSTEM_ARCH"
    printf "  - Debian 版本:     %s (PVE %s)\n" "$DEBIAN_CODENAME" "$PVE_VERSION"
    printf "  - 主机名 (FQDN):   %s\n" "$HOSTNAME_FQDN"
    printf "  - 服务器 IP:       %s\n" "$SERVER_IP"
    printf "  - 使用软件源:      %s\n" "$MIRROR_BASE"
    printf "============================================================\n"

    local final_confirm
    read -p "即将开始不可逆的安装过程，是否继续? (y/N): " final_confirm
    if [[ "${final_confirm,,}" != "y" ]]; then
        log_error "用户取消了安装。脚本退出。"
        exit 1
    fi

    backup_apt_config
    run_installation

    show_completion_info
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
