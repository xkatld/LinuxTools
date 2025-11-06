#!/bin/bash

set -euo pipefail

log_info() { echo "[INFO] $1"; }
log_ok() { echo "[OK] $1"; }
log_error() { echo "[ERROR] $1" >&2; }
log_warn() { echo "[WARN] $1"; }

check_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        log_error "需要 root 权限"
        exit 1
    fi
}

check_dependencies() {
    if ! command -v curl &>/dev/null; then
        log_error "未找到 curl 命令"
        exit 1
    fi
}

run_remote_script() {
    local url="$1"
    local description="$2"
    local args="${3:-}"

    log_warn "即将执行: ${description}"
    log_warn "URL: ${url}"
    if [[ -n "$args" ]]; then
        log_warn "参数: ${args}"
    fi

    read -p "确认执行? [Y/n]: " -r confirm
    confirm=${confirm:-Y}
    if [[ ! "$confirm" =~ ^[yY]$ ]]; then
        log_info "已取消"
        return 0
    fi

    log_info "执行命令: bash <(curl -sSL ${url}) ${args}"
    echo ""
    bash <(curl -sSL "$url") $args
    local exit_code=$?
    echo ""
    
    if [[ $exit_code -eq 0 ]]; then
        log_ok "'${description}' 执行成功"
    else
        log_error "'${description}' 执行失败 (退出码: $exit_code)"
    fi
}

show_menu() {
    clear 2>/dev/null || printf '\033[2J\033[H'
    echo "========================================="
    echo "  LinuxMirrors 脚本启动器"
    echo "========================================="
    echo "  1) 更换系统软件源 (国内)"
    echo "  2) 更换系统软件源 (海外)"
    echo "  3) 安装 Docker (国内镜像)"
    echo "  ---------------------------------------"
    echo "  0) 退出"
    echo "========================================="
}

main() {
    check_root
    check_dependencies
    
    while true; do
        show_menu
        read -p "请选择 [0-3]: " -r choice
        
        case "$choice" in
            "1")
                run_remote_script "https://linuxmirrors.cn/main.sh" "更换系统软件源 (国内)"
                break
                ;;
            "2")
                run_remote_script "https://linuxmirrors.cn/main.sh" "更换系统软件源 (海外)" "--abroad"
                break
                ;;
            "3")
                run_remote_script "https://linuxmirrors.cn/docker.sh" "安装 Docker (国内镜像)"
                break
                ;;
            "0")
                log_info "退出脚本"
                exit 0
                ;;
            *)
                log_error "无效选项: $choice"
                sleep 2
                ;;
        esac
    done
}

main "$@"
