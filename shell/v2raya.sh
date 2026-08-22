#!/bin/bash

set -euo pipefail

readonly ACCELERATOR_URL="https://ghfast.top"
readonly RELEASE_API="https://api.github.com/repos/v2rayA/v2rayA/releases/latest"

msg_info() { echo "[INFO] $1"; }
msg_ok() { echo "[OK] $1"; }
msg_error() { echo "[ERROR] $1" >&2; }

check_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        msg_error "此脚本需要 root 权限"
        exit 1
    fi
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

install_v2raya() {
    local version arch deb_name download_url temp_deb
    msg_info "正在获取 v2rayA 最新版本信息..."
    version=$(curl -s "$RELEASE_API" | grep '"tag_name":' | head -n 1 | sed -E 's/.*"([^"]+)".*/\1/' | tr -d 'v"')
    if [[ -z "$version" ]]; then
        msg_error "无法获取最新版本号"
        exit 1
    fi
    arch=$(get_arch)
    deb_name="installer_debian_${arch}_${version}.deb"
    download_url="${ACCELERATOR_URL}/https://github.com/v2rayA/v2rayA/releases/download/v${version}/${deb_name}"
    msg_info "检测到系统架构: ${arch}，最新版本: ${version}"
    msg_info "下载地址: ${download_url}"
    temp_deb=$(mktemp --suffix=.deb)
    trap "rm -f '$temp_deb'" EXIT
    if ! curl -fsSL "$download_url" -o "$temp_deb"; then
        msg_error "下载 deb 安装包失败"
        exit 1
    fi
    msg_info "正在安装 v2rayA 及依赖项..."
    apt-get update -y
    apt-get install -y "$temp_deb"
    systemctl enable --now v2raya
    msg_ok "v2rayA 安装并启动成功！Web UI 地址: http://localhost:2017"
}

main() {
    check_root
    install_v2raya
}

main "$@"
