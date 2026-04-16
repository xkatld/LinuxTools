#!/usr/bin/env bash
set -euo pipefail

TOOLBOX_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export TOOLBOX_ROOT

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
