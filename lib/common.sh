#!/usr/bin/env bash
set -euo pipefail

TOOLBOX_LOG="${TOOLBOX_LOG:-/tmp/linux-toolbox.log}"
mkdir -p "$(dirname "${TOOLBOX_LOG}")" 2>/dev/null || true

ts() { date '+%Y-%m-%d %H:%M:%S'; }

log_info() { echo "[$(ts)] [INFO] $*" | tee -a "${TOOLBOX_LOG}"; }
log_warn() { echo "[$(ts)] [WARN] $*" | tee -a "${TOOLBOX_LOG}"; }
log_error() { echo "[$(ts)] [ERROR] $*" | tee -a "${TOOLBOX_LOG}" >&2; }
log_ok() { echo "[$(ts)] [ OK ] $*" | tee -a "${TOOLBOX_LOG}"; }

clear_screen() {
    clear 2>/dev/null || printf '\033[2J\033[H'
}

pause_enter() {
    read -r -n 1 -s -p "按任意键继续..." _key
    echo
}

invalid_choice() {
    log_warn "无效选项，请重新输入。"
    pause_enter
}

confirm_action() {
    local prompt="${1:-确认继续吗}"
    read -r -p "${prompt} [y/N]: " answer
    [[ "${answer:-}" =~ ^[Yy]$ ]]
}

require_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        log_error "该操作需要 root 权限，请使用 sudo 或 root 运行。"
        return 1
    fi
}

backup_file() {
    local file="$1"
    [[ -f "${file}" ]] || return 0
    local backup_dir="/tmp/linux-toolbox-backups/$(date '+%Y%m%d_%H%M%S')"
    mkdir -p "${backup_dir}"
    cp -a "${file}" "${backup_dir}/"
    TOOLBOX_BACKUP_LAST_DIR="${backup_dir}"
    TOOLBOX_BACKUP_LAST_FILE="${backup_dir}/$(basename "${file}")"
    export TOOLBOX_BACKUP_LAST_DIR TOOLBOX_BACKUP_LAST_FILE
    log_ok "已备份 ${file} -> ${backup_dir}/"
}

run_cmd() {
    log_info "执行: $*"
    "$@"
}

init_runtime() {
    : > /dev/null
}
