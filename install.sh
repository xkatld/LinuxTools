#!/usr/bin/env bash
set -euo pipefail

TOOLBOX_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export TOOLBOX_ROOT

bootstrap_toolbox_from_archive() {
    local ref archive_url tmp_dir archive_file extracted_root

    ref="${TOOLBOX_BOOTSTRAP_REF:-feat/linux-toolbox-v1}"
    archive_url="${TOOLBOX_BOOTSTRAP_ARCHIVE_URL:-https://github.com/luckxine/LinuxTools/archive/refs/heads/${ref}.tar.gz}"
    tmp_dir="$(mktemp -d /tmp/linux-toolbox-bootstrap.XXXXXX)"
    archive_file="${tmp_dir}/toolbox.tar.gz"

    echo "检测到当前仅有 install.sh，正在拉取完整工具箱..." >&2

    if command -v curl >/dev/null 2>&1; then
        curl -fsSL "${archive_url}" -o "${archive_file}"
    elif command -v wget >/dev/null 2>&1; then
        wget -qO "${archive_file}" "${archive_url}"
    else
        echo "错误: 缺少 curl 或 wget，无法自动拉取完整工具箱。" >&2
        exit 1
    fi

    tar -xzf "${archive_file}" -C "${tmp_dir}"
    extracted_root="$(find "${tmp_dir}" -mindepth 1 -maxdepth 2 -type f -name install.sh | head -n 1 | xargs -r dirname)"

    if [[ -z "${extracted_root}" || ! -f "${extracted_root}/lib/common.sh" ]]; then
        echo "错误: 自动拉取的工具箱结构不完整，请检查下载源: ${archive_url}" >&2
        exit 1
    fi

    exec bash "${extracted_root}/install.sh" "$@"
}

if [[ ! -f "${TOOLBOX_ROOT}/lib/common.sh" ]]; then
    bootstrap_toolbox_from_archive "$@"
fi

# shellcheck source=lib/common.sh
source "${TOOLBOX_ROOT}/lib/common.sh"
# shellcheck source=lib/detect.sh
source "${TOOLBOX_ROOT}/lib/detect.sh"
# shellcheck source=lib/ui.sh
source "${TOOLBOX_ROOT}/lib/ui.sh"
# shellcheck source=modules/system.sh
source "${TOOLBOX_ROOT}/modules/system.sh"
# shellcheck source=modules/security.sh
source "${TOOLBOX_ROOT}/modules/security.sh"
# shellcheck source=modules/network.sh
source "${TOOLBOX_ROOT}/modules/network.sh"
# shellcheck source=modules/docker.sh
source "${TOOLBOX_ROOT}/modules/docker.sh"
# shellcheck source=modules/mirrors.sh
source "${TOOLBOX_ROOT}/modules/mirrors.sh"

main_menu() {
    clear_screen
    print_banner
    cat <<'EOF'
1) 系统基础管理
2) SSH 与安全管理
3) 网络诊断与优化
4) Docker 与服务环境
5) 换源
0) 退出
EOF
}

main() {
    if [[ "${1:-}" == "--menu-only" ]]; then
        main_menu
        exit 0
    fi

    init_runtime

    while true; do
        main_menu
        read -r -p "请输入选项: " choice
        case "${choice}" in
            1) module_system_menu ;;
            2) module_security_menu ;;
            3) module_network_menu ;;
            4) module_docker_menu ;;
            5) module_mirrors_menu ;;
            0) log_info "感谢使用，再见。"; exit 0 ;;
            *) invalid_choice ;;
        esac
    done
}

main "$@"
