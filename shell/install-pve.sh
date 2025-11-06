#!/bin/bash

set -euo pipefail

SYSTEM_ARCH=""
DEBIAN_CODENAME=""
DEBIAN_VERSION=""
PVE_VERSION=""
HOSTNAME_FQDN=""
SERVER_IP=""
MIRROR_BASE=""
PVE_REPO_COMPONENT=""
PVE_GPG_KEY_URL=""

log_info() { echo "[INFO] $1"; }
log_warn() { echo "[WARN] $1"; }
log_error() { echo "[ERROR] $1" >&2; }
log_step() { echo ""; echo "=> $1"; echo ""; }

cleanup_on_exit() {
    log_warn "脚本被中断或发生错误，正在退出..."
    exit 1
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "此脚本必须以 root 权限运行，请使用 sudo"
        exit 1
    fi
}

detect_architecture() {
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
            log_info "仅支持 amd64 (x86_64) 和 arm64 (aarch64)"
            exit 1
            ;;
    esac
    log_info "系统架构: ${SYSTEM_ARCH}"
}

check_dependencies() {
    local missing_deps=()
    
    for cmd in curl lsb_release; do
        if ! command -v "$cmd" &>/dev/null; then
            missing_deps+=("$cmd")
        fi
    done

    if [[ ${#missing_deps[@]} -gt 0 ]]; then
        log_error "缺少必要命令: ${missing_deps[*]}"
        log_info "请运行: apt-get update && apt-get install -y curl lsb-release"
        exit 1
    fi
}

detect_debian_version() {
    if [[ ! -f /etc/debian_version ]]; then
        log_error "未检测到 Debian 系统"
        exit 1
    fi
    
    DEBIAN_CODENAME=$(lsb_release -cs)
    DEBIAN_VERSION=$(lsb_release -rs | cut -d. -f1)

    case "$DEBIAN_CODENAME" in
        bullseye)
            PVE_VERSION="7"
            log_info "Debian 11 (Bullseye) → Proxmox VE ${PVE_VERSION}"
            ;;
        bookworm)
            PVE_VERSION="8"
            log_info "Debian 12 (Bookworm) → Proxmox VE ${PVE_VERSION}"
            ;;
        trixie)
            if [[ "$SYSTEM_ARCH" == "arm64" ]]; then
                log_error "ARM64 不支持 Debian 13"
                exit 1
            fi
            PVE_VERSION="9"
            log_info "Debian 13 (Trixie) → Proxmox VE ${PVE_VERSION}"
            ;;
        *)
            log_error "不支持的 Debian 版本: ${DEBIAN_CODENAME}"
            log_info "支持的版本: Debian 11/12 (AMD64+ARM64), Debian 13 (仅AMD64)"
            exit 1
            ;;
    esac
}

configure_mirror() {
    if [[ "$SYSTEM_ARCH" == "amd64" ]]; then
        log_info "使用 Proxmox 官方源"
        MIRROR_BASE="http://download.proxmox.com/debian/pve"
        PVE_REPO_COMPONENT="pve-no-subscription"
        
        if [[ "$DEBIAN_CODENAME" == "trixie" ]]; then
            PVE_GPG_KEY_URL="https://enterprise.proxmox.com/debian/proxmox-archive-keyring-trixie.gpg"
        else
            PVE_GPG_KEY_URL="https://enterprise.proxmox.com/debian/proxmox-release-${DEBIAN_CODENAME}.gpg"
        fi
    else
        log_info "ARM64 架构 - 选择第三方镜像源"
        echo ""
        echo "可用镜像源："
        echo "  1) 韩国镜像 (mirrors.apqa.cn)"
        echo "  2) 中国镜像 (mirrors.lierfang.com)"
        echo "  3) 香港镜像 (hk.mirrors.apqa.cn)"
        echo "  4) 德国镜像 (de.mirrors.apqa.cn)"
        echo ""
        
        local choice mirror_domain
        while true; do
            read -p "请选择 [1-4, 默认1]: " -r choice
            choice=${choice:-1}
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
        log_info "已选择: ${mirror_domain}"
    fi
}

configure_network() {
    log_step "配置网络"
    
    local hostname domain default_ip
    
    read -p "主机名 [默认: pve]: " -r hostname
    hostname=${hostname:-pve}
    
    read -p "域名 [默认: local]: " -r domain
    domain=${domain:-local}
    
    HOSTNAME_FQDN="${hostname}.${domain}"

    log_info "正在检测服务器 IP..."
    default_ip=$(curl -s --connect-timeout 3 4.ipw.cn 2>/dev/null || echo "")
    
    if [[ -z "$default_ip" ]]; then
        default_ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    fi

    while true; do
        if [[ -n "$default_ip" ]]; then
            read -p "服务器 IP 地址 [默认: ${default_ip}]: " -r SERVER_IP
            SERVER_IP=${SERVER_IP:-$default_ip}
        else
            read -p "服务器 IP 地址 (如 192.168.1.10): " -r SERVER_IP
        fi
        
        if [[ -z "$SERVER_IP" ]]; then
            log_warn "IP 地址不能为空"
        elif [[ $SERVER_IP =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
            break
        else
            log_warn "IP 地址格式无效"
        fi
    done

    echo ""
    echo "网络配置："
    echo "  FQDN: ${HOSTNAME_FQDN}"
    echo "  IP:   ${SERVER_IP}"
    echo ""
    
    read -p "确认并应用? [Y/n]: " -r confirm
    confirm=${confirm:-Y}
    if [[ ! "$confirm" =~ ^[yY]$ ]]; then
        log_error "配置已取消"
        exit 1
    fi

    hostnamectl set-hostname "$HOSTNAME_FQDN" --static
    log_info "主机名已设置"

    cat > /etc/hosts << EOF
127.0.0.1       localhost
::1             localhost ip6-localhost ip6-loopback
ff02::1         ip6-allnodes
ff02::2         ip6-allrouters
${SERVER_IP}    ${HOSTNAME_FQDN} ${hostname}
EOF
    log_info "/etc/hosts 已更新"
}

backup_apt_sources() {
    local backup_dir="/root/pve_backup_$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$backup_dir"
    find /etc/apt/ -name "*.list" -exec cp {} "$backup_dir/" \; 2>/dev/null || true
    log_info "APT 配置已备份至: ${backup_dir}"
}

install_proxmox() {
    log_step "安装 Proxmox VE"
    
    log_info "下载 GPG 密钥..."
    local gpg_key_name gpg_key_path
    gpg_key_name=$(basename "$PVE_GPG_KEY_URL")
    
    if [[ "$DEBIAN_CODENAME" == "trixie" && "$SYSTEM_ARCH" == "amd64" ]]; then
        gpg_key_path="/usr/share/keyrings/${gpg_key_name}"
        mkdir -p /usr/share/keyrings
    else
        gpg_key_path="/etc/apt/trusted.gpg.d/${gpg_key_name}"
    fi
    
    if ! curl -fsSL "${PVE_GPG_KEY_URL}" -o "${gpg_key_path}"; then
        log_error "GPG 密钥下载失败"
        exit 1
    fi
    chmod 644 "${gpg_key_path}"
    log_info "GPG 密钥: ${gpg_key_path}"

    log_info "配置 APT 源..."
    if [[ "$DEBIAN_CODENAME" == "trixie" && "$SYSTEM_ARCH" == "amd64" ]]; then
        cat > /etc/apt/sources.list.d/pve-install-repo.sources << EOF
Types: deb
URIs: ${MIRROR_BASE}
Suites: ${DEBIAN_CODENAME}
Components: ${PVE_REPO_COMPONENT}
Signed-By: ${gpg_key_path}
EOF
        log_info "APT 源: ${MIRROR_BASE} (deb822)"
    else
        echo "deb ${MIRROR_BASE} ${DEBIAN_CODENAME} ${PVE_REPO_COMPONENT}" > /etc/apt/sources.list.d/pve.list
        log_info "APT 源: ${MIRROR_BASE}"
    fi
    
    log_info "更新软件包列表..."
    if ! apt-get update; then
        log_error "apt-get update 失败"
        exit 1
    fi
    
    log_info "预配置 GRUB..."
    echo 'grub-pc grub-pc/install_devices_empty boolean true' | debconf-set-selections 2>/dev/null || true
    
    log_info "升级系统..."
    export DEBIAN_FRONTEND=noninteractive
    if ! apt-get full-upgrade -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold"; then
        log_error "apt-get full-upgrade 失败"
        exit 1
    fi
    
    log_info "安装 Proxmox VE (需要几分钟)..."
    export DEBIAN_FRONTEND=noninteractive
    if ! apt-get install -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" proxmox-ve postfix open-iscsi chrony; then
        log_error "Proxmox VE 安装失败"
        exit 1
    fi

    log_info "安装完成"
}

show_completion() {
    local ip
    ip=$(hostname -I | awk '{print $1}')

    echo ""
    echo "========================================"
    echo "  Proxmox VE ${PVE_VERSION} 安装完成"
    echo "========================================"
    echo ""
    echo "Web 管理界面："
    echo "  URL:    https://${ip}:8006/"
    echo "  用户名: root"
    echo "  密码:   (系统 root 密码)"
    echo ""
    echo "========================================"
    echo ""
    
    log_warn "需要重启以加载 Proxmox 内核"
    read -p "立即重启? [Y/n]: " -r reboot_confirm
    reboot_confirm=${reboot_confirm:-Y}
    if [[ "$reboot_confirm" =~ ^[yY]$ ]]; then
        log_info "系统将在 5 秒后重启..."
        sleep 5
        reboot
    else
        log_warn "请稍后手动执行: reboot"
    fi
}

main() {
    trap cleanup_on_exit INT TERM
    
    echo ""
    echo "========================================"
    echo "  Proxmox VE 安装脚本"
    echo "  支持: AMD64 / ARM64"
    echo "========================================"
    echo ""

    log_step "系统检查"
    check_root
    detect_architecture
    check_dependencies
    detect_debian_version
    
    log_step "配置软件源"
    configure_mirror

    configure_network
    
    echo ""
    echo "========================================"
    echo "  安装信息确认"
    echo "========================================"
    echo ""
    echo "系统："
    echo "  架构:   ${SYSTEM_ARCH}"
    echo "  版本:   Debian ${DEBIAN_VERSION} (${DEBIAN_CODENAME})"
    echo "  PVE:    Proxmox VE ${PVE_VERSION}"
    echo ""
    echo "网络："
    echo "  主机名: ${HOSTNAME_FQDN}"
    echo "  IP:     ${SERVER_IP}"
    echo ""
    echo "软件源："
    echo "  ${MIRROR_BASE}"
    echo ""
    echo "========================================"
    echo ""

    read -p "确认开始安装? (此操作不可逆) [Y/n]: " -r final_confirm
    final_confirm=${final_confirm:-Y}
    if [[ ! "$final_confirm" =~ ^[yY]$ ]]; then
        log_error "安装已取消"
        exit 1
    fi

    backup_apt_sources
    install_proxmox
    show_completion
}

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && main "$@"
