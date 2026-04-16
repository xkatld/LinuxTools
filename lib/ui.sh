#!/usr/bin/env bash
set -euo pipefail

print_banner() {
    ensure_os_detected
    cat <<EOF
=========================================
 Linux 工具箱 V1
 系统: ${OS_PRETTY_NAME:-未知}
 日志: ${TOOLBOX_LOG}
=========================================
EOF
}

print_section() {
    echo
    echo "========== $* =========="
}
