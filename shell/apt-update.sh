#!/bin/bash

set -euo pipefail

log_info() { echo "[INFO] $1"; }
log_ok() { echo "[OK] $1"; }
log_error() { echo "[ERROR] $1" >&2; }
log_warn() { echo "[WARN] $1"; }

check_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        log_error "需要 root 权限，请使用 sudo"
        exit 1
    fi
}

check_distro() {
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        if [[ "$ID" == "debian" || "$ID" == "ubuntu" ]]; then
            log_ok "系统: $PRETTY_NAME"
        else
            log_error "仅支持 Debian 和 Ubuntu，当前系统: $ID"
            exit 1
        fi
    else
        log_error "无法检测操作系统"
        exit 1
    fi
}

run_upgrade() {
    log_info "更新软件包列表..."
    apt-get update
    
    log_info "升级已安装软件包..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get upgrade -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold"
    
    log_info "执行发行版升级..."
    apt-get dist-upgrade -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold"
    
    log_ok "系统更新完成"
}

show_cleanup_info() {
    echo ""
    log_info "建议清理命令:"
    echo "  1) 移除不需要的依赖: apt autoremove"
    echo "  2) 清理软件包缓存:   apt clean"
    echo ""
}

cleanup_old_kernels() {
    log_info "扫描旧内核..."
    
    local current_kernel
    current_kernel=$(uname -r)
    local installed_kernels
    installed_kernels=($(dpkg-query -W -f='${Package}\n' 'linux-image-[0-9]*' 2>/dev/null | grep -v "${current_kernel}" || true))
    
    if [[ ${#installed_kernels[@]} -eq 0 ]]; then
        log_ok "没有可清理的旧内核"
        return
    fi
    
    log_warn "发现旧内核:"
    for kernel in "${installed_kernels[@]}"; do
        echo "  - $kernel"
    done
    
    echo ""
    read -p "是否移除这些旧内核? [Y/n]: " -r confirm
    confirm=${confirm:-Y}
    if [[ ! "$confirm" =~ ^[yY]$ ]]; then
        log_info "已取消"
        return
    fi
    
    log_info "移除旧内核..."
    printf "%s\n" "${installed_kernels[@]}" | xargs apt-get purge -y
    log_ok "旧内核已清理"
    
    log_info "更新 GRUB..."
    update-grub
    log_ok "GRUB 配置已更新"
}

main() {
    clear 2>/dev/null || printf '\033[2J\033[H'
    
    echo "========================================"
    echo "  Debian/Ubuntu 系统更新脚本"
    echo "========================================"
    echo ""
    
    check_root
    check_distro
    
    echo ""
    read -p "开始系统更新? [Y/n]: " -r confirm_start
    confirm_start=${confirm_start:-Y}
    if [[ ! "$confirm_start" =~ ^[yY]$ ]]; then
        log_info "已取消"
        exit 0
    fi
    
    run_upgrade
    show_cleanup_info
    
    read -p "是否清理旧内核? [y/N]: " -r confirm_kernel
    confirm_kernel=${confirm_kernel:-N}
    if [[ "$confirm_kernel" =~ ^[yY]$ ]]; then
        cleanup_old_kernels
    fi
    
    log_ok "所有操作已完成，建议重启系统"
}

main "$@"
