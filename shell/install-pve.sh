#!/bin/bash
# Proxmox VE Installer v2.0 - Author: xkatld

set -o errexit
set -o nounset
set -o pipefail

readonly COLOR_RED='\033[0;31m'
readonly COLOR_GREEN='\033[0;32m'
readonly COLOR_YELLOW='\033[1;33m'
readonly COLOR_BLUE='\033[0;34m'
readonly COLOR_CYAN='\033[0;36m'
readonly COLOR_NC='\033[0m'

SYSTEM_ARCH=""
DEBIAN_CODENAME=""
DEBIAN_VERSION=""
PVE_VERSION=""
HOSTNAME_FQDN=""
SERVER_IP=""
MIRROR_BASE=""
PVE_REPO_COMPONENT=""
PVE_GPG_KEY_URL=""

log_info() { printf "${COLOR_GREEN}[✓]${COLOR_NC} %s\n" "$1"; }
log_warn() { printf "${COLOR_YELLOW}[!]${COLOR_NC} %s\n" "$1"; }
log_error() { printf "${COLOR_RED}[✗]${COLOR_NC} %s\n" "$1"; }
log_step() { printf "\n${COLOR_CYAN}▶ %s${COLOR_NC}\n" "$1"; }

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
    DEBIAN_VERSION=$(lsb_release -rs | cut -d. -f1)

    case "$DEBIAN_CODENAME" in
        bullseye)
            PVE_VERSION="7"
            log_info "检测到 Debian 11 (Bullseye) → 将安装 Proxmox VE $PVE_VERSION"
            ;;
        bookworm)
            PVE_VERSION="8"
            log_info "检测到 Debian 12 (Bookworm) → 将安装 Proxmox VE $PVE_VERSION"
            ;;
        trixie)
            PVE_VERSION="9"
            log_info "检测到 Debian 13 (Trixie) → 将安装 Proxmox VE $PVE_VERSION"
            log_warn "Debian 13 支持可能处于测试阶段，建议在生产环境使用 Debian 12。"
            ;;
        *)
            log_error "不支持的 Debian 版本: $DEBIAN_CODENAME"
            log_info "支持的版本: Debian 11 (bullseye), Debian 12 (bookworm), Debian 13 (trixie)"
            exit 1
            ;;
    esac
}

function configure_architecture_specifics() {
    log_step "根据架构 (${SYSTEM_ARCH}) 配置软件源"

    if [[ "$SYSTEM_ARCH" == "amd64" ]]; then
        log_info "AMD64 架构 → 使用 Proxmox 官方软件源"
        MIRROR_BASE="http://download.proxmox.com/debian/pve"
        PVE_REPO_COMPONENT="pve-no-subscription"
        PVE_GPG_KEY_URL="https://enterprise.proxmox.com/debian/proxmox-release-${DEBIAN_CODENAME}.gpg"
    else
        log_info "ARM64 架构 → 选择第三方镜像源"
        local choice mirror_domain
        
        cat << EOF

${COLOR_YELLOW}请选择镜像源（建议选择地理位置较近的）：${COLOR_NC}
  ${COLOR_CYAN}1)${COLOR_NC} 韩国镜像 (mirrors.apqa.cn)
  ${COLOR_CYAN}2)${COLOR_NC} 中国镜像 (mirrors.lierfang.com)
  ${COLOR_CYAN}3)${COLOR_NC} 香港镜像 (hk.mirrors.apqa.cn)
  ${COLOR_CYAN}4)${COLOR_NC} 德国镜像 (de.mirrors.apqa.cn)

EOF
        while true; do
            read -p "请输入选项 (1-4): " -r choice
            case $choice in
                1) mirror_domain="https://mirrors.apqa.cn"; break ;;
                2) mirror_domain="https://mirrors.lierfang.com"; break ;;
                3) mirror_domain="https://hk.mirrors.apqa.cn"; break ;;
                4) mirror_domain="https://de.mirrors.apqa.cn"; break ;;
                *) log_warn "无效选项，请输入 1-4" ;;
            esac
        done
        
        MIRROR_BASE="${mirror_domain}/proxmox/debian/pve"
        PVE_REPO_COMPONENT="port"
        PVE_GPG_KEY_URL="${mirror_domain}/proxmox/debian/pveport.gpg"
    fi
    
    log_info "软件源: ${MIRROR_BASE}"
    log_info "GPG密钥: ${PVE_GPG_KEY_URL}"
}

function configure_hostname() {
    log_step "配置主机名和 /etc/hosts 文件"
    
    local hostname domain
    
    while true; do
        read -p "请输入主机名 (如: pve): " -r hostname
        [[ -n "$hostname" ]] && break
        log_warn "主机名不能为空"
    done

    while true; do
        read -p "请输入域名 (如: local): " -r domain
        [[ -n "$domain" ]] && break
        log_warn "域名不能为空"
    done
    
    HOSTNAME_FQDN="${hostname}.${domain}"

    while true; do
        read -p "请输入服务器静态 IP (如: 192.168.1.10): " -r SERVER_IP
        if [[ -z "$SERVER_IP" ]]; then
            log_warn "IP 地址不能为空"
        elif [[ $SERVER_IP =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
            break
        else
            log_warn "IP 地址格式无效"
        fi
    done

    printf "\n${COLOR_YELLOW}配置预览：${COLOR_NC}\n"
    printf "  完整主机名: ${COLOR_CYAN}%s${COLOR_NC}\n" "${HOSTNAME_FQDN}"
    printf "  IP 地址:    ${COLOR_CYAN}%s${COLOR_NC}\n\n" "${SERVER_IP}"
    
    read -p "是否应用此配置并修改 /etc/hosts? (y/N): " -r confirm_hosts
    [[ "${confirm_hosts,,}" != "y" ]] && { log_warn "操作已取消"; return 1; }

    hostnamectl set-hostname "$HOSTNAME_FQDN" --static
    log_info "主机名已设置: $HOSTNAME_FQDN"

    cat > /etc/hosts << EOF
127.0.0.1       localhost
::1             localhost ip6-localhost ip6-loopback
ff02::1         ip6-allnodes
ff02::2         ip6-allrouters
${SERVER_IP}    ${HOSTNAME_FQDN} ${hostname}
EOF
    log_info "/etc/hosts 已更新"
}

function backup_apt_config() {
    log_step "备份当前 APT 源配置"
    
    local backup_dir="/root/pve_install_backup_$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$backup_dir" || { log_error "无法创建备份目录"; return 1; }
    log_info "备份目录: $backup_dir"
    
    find /etc/apt/ -name "*.list" -exec cp {} "$backup_dir/" \; 2>/dev/null
    log_info "APT 配置已备份"
}

function run_installation() {
    log_step "开始安装 Proxmox VE"
    
    log_info "下载 GPG 密钥..."
    local gpg_key_name
    gpg_key_name=$(basename "$PVE_GPG_KEY_URL")
    if ! curl -fsSL "${PVE_GPG_KEY_URL}" -o "/etc/apt/trusted.gpg.d/${gpg_key_name}"; then
        log_error "GPG 密钥下载失败，请检查网络连接"
        exit 1
    fi
    chmod 644 "/etc/apt/trusted.gpg.d/${gpg_key_name}"
    log_info "GPG 密钥已安装"

    log_info "配置 Proxmox VE APT 源..."
    echo "deb ${MIRROR_BASE} ${DEBIAN_CODENAME} ${PVE_REPO_COMPONENT}" > /etc/apt/sources.list.d/pve.list
    log_info "APT 源已配置"
    
    log_info "更新软件包列表..."
    if ! apt-get update; then
        log_error "软件包列表更新失败"
        exit 1
    fi
    
    log_info "安装 Proxmox VE 核心包（可能需要几分钟）..."
    export DEBIAN_FRONTEND=noninteractive
    if ! apt-get install -y proxmox-ve postfix open-iscsi chrony; then
        log_error "Proxmox VE 安装失败"
        exit 1
    fi

    log_info "Proxmox VE 安装成功！"
}

function show_completion_info() {
    local ip
    ip=$(hostname -I | awk '{print $1}')

    cat << EOF

${COLOR_GREEN}============================================================
    🎉 Proxmox VE ${PVE_VERSION} 安装完成！
============================================================${COLOR_NC}

${COLOR_CYAN}Web 管理界面访问信息：${COLOR_NC}
  ${COLOR_YELLOW}URL:${COLOR_NC}      https://${ip}:8006/
  ${COLOR_YELLOW}用户名:${COLOR_NC}   root
  ${COLOR_YELLOW}密码:${COLOR_NC}     (您的系统 root 密码)

EOF
    
    log_warn "需要重启系统以加载 Proxmox 内核"
    read -p "是否立即重启? (y/N): " -r reboot_confirm
    if [[ "${reboot_confirm,,}" == "y" ]]; then
        log_info "系统将在 5 秒后重启..."
        sleep 5
        reboot
    else
        log_warn "请稍后手动执行 'reboot' 命令重启系统"
    fi
}

function main() {
    trap cleanup_on_exit INT TERM
    
    cat << EOF

${COLOR_CYAN}╔════════════════════════════════════════════════════════╗
║   Proxmox VE 自动安装脚本 v2.0                        ║
║   支持: AMD64 / ARM64                                  ║
║   作者: xkatld                                         ║
╚════════════════════════════════════════════════════════╝${COLOR_NC}

EOF

    check_prerequisites
    check_debian_version
    configure_architecture_specifics

    configure_hostname || { log_error "主机名配置失败"; exit 1; }
    
    cat << EOF

${COLOR_YELLOW}╔════════════════════════════════════════════════════════╗
║                    最终安装确认                        ║
╚════════════════════════════════════════════════════════╝${COLOR_NC}

${COLOR_CYAN}系统信息：${COLOR_NC}
  架构:        ${COLOR_GREEN}${SYSTEM_ARCH}${COLOR_NC}
  系统版本:    ${COLOR_GREEN}Debian ${DEBIAN_VERSION} (${DEBIAN_CODENAME})${COLOR_NC}
  PVE 版本:    ${COLOR_GREEN}Proxmox VE ${PVE_VERSION}${COLOR_NC}
  
${COLOR_CYAN}网络配置：${COLOR_NC}
  主机名:      ${COLOR_GREEN}${HOSTNAME_FQDN}${COLOR_NC}
  IP 地址:     ${COLOR_GREEN}${SERVER_IP}${COLOR_NC}
  
${COLOR_CYAN}软件源：${COLOR_NC}
  ${COLOR_GREEN}${MIRROR_BASE}${COLOR_NC}

EOF

    read -p "${COLOR_YELLOW}确认开始安装？此操作不可逆！(y/N):${COLOR_NC} " -r final_confirm
    [[ "${final_confirm,,}" != "y" ]] && { log_error "安装已取消"; exit 1; }

    backup_apt_config
    run_installation
    show_completion_info
}

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && main "$@"
