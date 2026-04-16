#!/usr/bin/env bash
set -euo pipefail

OS_ID=""
OS_VERSION=""
OS_PRETTY_NAME=""
PKG_MANAGER=""
PKG_UPDATE_CMD=()
PKG_INSTALL_CMD=()

ensure_os_detected() {
    if [[ -n "${OS_ID}" ]]; then
        return 0
    fi

    if [[ -f /etc/os-release ]]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        OS_ID="${ID:-unknown}"
        OS_VERSION="${VERSION_ID:-unknown}"
        OS_PRETTY_NAME="${PRETTY_NAME:-${OS_ID}}"
    else
        OS_ID="unknown"
        OS_VERSION="unknown"
        OS_PRETTY_NAME="unknown"
    fi

    case "${OS_ID}" in
        ubuntu|debian)
            PKG_MANAGER="apt"
            PKG_UPDATE_CMD=(apt-get update)
            PKG_INSTALL_CMD=(apt-get install -y)
            ;;
        centos|rhel|rocky|almalinux)
            PKG_MANAGER="yum"
            PKG_UPDATE_CMD=(yum makecache)
            PKG_INSTALL_CMD=(yum install -y)
            ;;
        fedora)
            PKG_MANAGER="dnf"
            PKG_UPDATE_CMD=(dnf makecache)
            PKG_INSTALL_CMD=(dnf install -y)
            ;;
        alpine)
            PKG_MANAGER="apk"
            PKG_UPDATE_CMD=(apk update)
            PKG_INSTALL_CMD=(apk add)
            ;;
        *)
            PKG_MANAGER="unknown"
            PKG_UPDATE_CMD=()
            PKG_INSTALL_CMD=()
            ;;
    esac
}

show_os_summary() {
    ensure_os_detected
    echo "系统: ${OS_PRETTY_NAME}"
    echo "系统标识: ${OS_ID}"
    echo "包管理器: ${PKG_MANAGER}"
}

update_package_index() {
    require_root || return 1
    ensure_os_detected
    [[ "${PKG_MANAGER}" != "unknown" ]] || { log_error "暂不支持当前系统的包管理器。"; return 1; }
    run_cmd "${PKG_UPDATE_CMD[@]}"
}

install_packages() {
    require_root || return 1
    ensure_os_detected
    [[ "${PKG_MANAGER}" != "unknown" ]] || { log_error "暂不支持当前系统的包管理器。"; return 1; }
    run_cmd "${PKG_INSTALL_CMD[@]}" "$@"
}
