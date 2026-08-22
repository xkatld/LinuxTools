#!/bin/bash

set -euo pipefail

readonly ACCELERATOR_URL="https://ghfast.top"
readonly DEFAULT_VERSION="2.2.5"

msg_info() { echo "[INFO] $1"; }
msg_ok() { echo "[OK] $1"; }
msg_error() { echo "[ERROR] $1" >&2; }

check_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        msg_error "此脚本需要 root 权限"
        exit 1
    fi
}

check_deps() {
    local deps=("curl" "mktemp" "unzip" "iptables")
    for cmd in "${deps[@]}"; do
        if ! command -v "$cmd" &>/dev/null; then
            msg_info "正在安装必要依赖 $cmd..."
            apt-get update -y && apt-get install -y "$cmd"
        fi
    done
}

get_arch() {
    local arch
    arch=$(uname -m)
    case "$arch" in
        x86_64) echo "x64" ;;
        aarch64) echo "arm64" ;;
        armv7l) echo "armv7" ;;
        i386|i686) echo "x86" ;;
        *) echo "x64" ;;
    esac
}

install_v2raya_deb() {
    if command -v v2raya &>/dev/null || dpkg -l v2raya &>/dev/null; then
        msg_ok "v2rayA 主程序已安装，跳过下载。"
        return 0
    fi
    local version arch deb_name download_url temp_deb
    version="${DEFAULT_VERSION}"
    arch=$(get_arch)
    deb_name="installer_debian_${arch}_${version}.deb"
    download_url="${ACCELERATOR_URL}/https://github.com/v2rayA/v2rayA/releases/download/v${version}/${deb_name}"
    msg_info "检测到系统架构: ${arch}，预设大版本: ${version}"
    msg_info "下载地址: ${download_url}"
    temp_deb=$(mktemp --suffix=.deb)
    trap "rm -f '$temp_deb'" EXIT
    if ! curl -fsSL "$download_url" -o "$temp_deb"; then
        msg_error "下载 deb 安装包失败"
        exit 1
    fi
    msg_info "正在安装 v2rayA..."
    apt-get update -y
    apt-get install -y "$temp_deb"
    msg_ok "v2rayA 主程序安装完成。"
}

install_rules() {
    if [[ -f /usr/local/share/v2ray/geosite.dat && -f /usr/local/share/v2ray/geoip.dat ]]; then
        msg_ok "geosite.dat 与 geoip.dat 规则数据库已存在，跳过下载。"
        return 0
    fi
    msg_info "正在创建规则文件存储目录..."
    mkdir -p /usr/local/share/v2ray /usr/share/v2ray /usr/local/share/xray /usr/share/xray
    
    msg_info "正在下载 geosite.dat 与 geoip.dat 规则文件..."
    local geosite_url geoip_url
    geosite_url="${ACCELERATOR_URL}/https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat"
    geoip_url="${ACCELERATOR_URL}/https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat"
    
    curl -fsSL "$geosite_url" -o /usr/local/share/v2ray/geosite.dat
    curl -fsSL "$geoip_url" -o /usr/local/share/v2ray/geoip.dat
    
    cp -f /usr/local/share/v2ray/geosite.dat /usr/share/v2ray/geosite.dat
    cp -f /usr/local/share/v2ray/geoip.dat /usr/share/v2ray/geoip.dat
    cp -f /usr/local/share/v2ray/geosite.dat /usr/local/share/xray/geosite.dat
    cp -f /usr/local/share/v2ray/geoip.dat /usr/local/share/xray/geoip.dat
    cp -f /usr/local/share/v2ray/geosite.dat /usr/share/xray/geosite.dat
    cp -f /usr/local/share/v2ray/geoip.dat /usr/share/xray/geoip.dat
    msg_ok "规则数据库部署完成。"
}

install_core() {
    if [[ -x /usr/local/bin/v2ray || -x /usr/bin/v2ray ]]; then
        msg_ok "v2ray-core 内核已存在，跳过下载。"
        return 0
    fi
    mkdir -p /usr/local/bin
    local arch temp_dir core_file core_url
    arch=$(get_arch)
    msg_info "正在下载 v2ray-core 内核..."
    case "$arch" in
        x64) core_file="v2ray-linux-64.zip" ;;
        arm64) core_file="v2ray-linux-arm64-v8a.zip" ;;
        armv7) core_file="v2ray-linux-arm32-v7a.zip" ;;
        x86) core_file="v2ray-linux-32.zip" ;;
        *) core_file="v2ray-linux-64.zip" ;;
    esac
    
    core_url="${ACCELERATOR_URL}/https://github.com/v2fly/v2ray-core/releases/download/v5.28.0/${core_file}"
    temp_dir=$(mktemp -d)
    trap "rm -rf '$temp_dir'" EXIT
    
    if curl -fsSL "$core_url" -o "$temp_dir/v2ray.zip"; then
        unzip -q -o "$temp_dir/v2ray.zip" -d "$temp_dir"
        if [[ -f "$temp_dir/v2ray" ]]; then
            cp -f "$temp_dir/v2ray" /usr/local/bin/v2ray
            cp -f "$temp_dir/v2ray" /usr/bin/v2ray
            chmod +x /usr/local/bin/v2ray /usr/bin/v2ray
            msg_ok "v2ray-core 内核安装完成。"
        fi
    fi
}

main() {
    check_root
    check_deps
    install_v2raya_deb
    install_rules
    install_core
    systemctl restart v2raya 2>/dev/null || true
    systemctl enable v2raya 2>/dev/null || true
    msg_ok "v2rayA 及相关环境准备就绪！Web UI 地址: http://localhost:2017"
}

main "$@"
