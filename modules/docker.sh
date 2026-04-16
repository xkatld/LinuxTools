#!/usr/bin/env bash
set -euo pipefail

docker_merge_daemon_json() {
    local daemon_file="$1"
    local mirror_url="$2"
    python3 - "$daemon_file" "$mirror_url" <<'PY'
import json
import pathlib
import sys

daemon_file = pathlib.Path(sys.argv[1])
mirror_url = sys.argv[2]

data = {}
if daemon_file.exists() and daemon_file.read_text(encoding="utf-8").strip():
    data = json.loads(daemon_file.read_text(encoding="utf-8"))

mirrors = data.get("registry-mirrors")
if not isinstance(mirrors, list):
    mirrors = []
if mirror_url not in mirrors:
    mirrors.append(mirror_url)
data["registry-mirrors"] = mirrors

daemon_file.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
PY
}

docker_clear_registry_mirrors() {
    local daemon_file="$1"
    python3 - "$daemon_file" <<'PY'
import json
import pathlib
import sys

daemon_file = pathlib.Path(sys.argv[1])
if daemon_file.exists() and daemon_file.read_text(encoding="utf-8").strip():
    data = json.loads(daemon_file.read_text(encoding="utf-8"))
else:
    data = {}

data.pop("registry-mirrors", None)
daemon_file.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
PY
}

docker_install_engine() {
    require_root || return 1
    print_section "安装 Docker"
    confirm_action "确认安装 Docker 吗" || { pause_enter; return 0; }
    curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
    bash /tmp/get-docker.sh
    if command -v systemctl >/dev/null 2>&1; then
        run_cmd systemctl enable --now docker
    fi
    docker --version
    log_ok "Docker 安装完成。"
    pause_enter
}

docker_install_compose() {
    require_root || return 1
    print_section "安装 Docker Compose 插件"
    if docker compose version >/dev/null 2>&1; then
        log_ok "Docker Compose 插件已存在。"
        docker compose version
        pause_enter
        return 0
    fi
    ensure_os_detected
    case "${PKG_MANAGER}" in
        apt|yum|dnf)
            install_packages docker-compose-plugin || true
            ;;
        *)
            log_warn "当前系统未提供标准包安装，若 Docker 已安装通常会自带 compose 插件。"
            ;;
    esac
    docker compose version || log_warn "未检测到 docker compose，请确认安装结果。"
    pause_enter
}

docker_configure_mirror() {
    module_docker_mirrors_menu
}

docker_show_containers() {
    clear_screen
    print_section "容器状态"
    docker ps -a
    pause_enter
}

docker_show_logs() {
    print_section "查看容器日志"
    read -r -p "请输入容器名或容器 ID: " container
    read -r -p "显示最近多少行 [默认 100]: " tail_lines
    tail_lines=${tail_lines:-100}
    [[ -n "${container}" ]] || { log_error "容器名不能为空。"; pause_enter; return 1; }
    docker logs --tail "${tail_lines}" "${container}"
    pause_enter
}

docker_show_engine_status() {
    clear_screen
    print_section "Docker 引擎状态"
    if ! command -v docker >/dev/null 2>&1; then
        log_warn "当前未检测到 docker 命令。"
        pause_enter
        return 1
    fi

    docker --version 2>/dev/null || true
    docker compose version 2>/dev/null || true
    echo

    if command -v systemctl >/dev/null 2>&1; then
        systemctl status docker --no-pager 2>/dev/null | sed -n '1,8p' || true
        echo
    fi

    if [[ -f /etc/docker/daemon.json ]]; then
        echo "daemon.json: /etc/docker/daemon.json"
        grep -n 'registry-mirrors' /etc/docker/daemon.json 2>/dev/null || true
    else
        echo "daemon.json: 未找到 /etc/docker/daemon.json"
    fi

    echo
    docker info 2>/dev/null | grep -A3 'Registry Mirrors' || true
    pause_enter
}

docker_prune() {
    require_root || return 1
    print_section "清理 Docker 垃圾"
    confirm_action "确认执行 docker system prune -af 吗" || { pause_enter; return 0; }
    docker system prune -af
    log_ok "Docker 垃圾已清理。"
    pause_enter
}

docker_render_menu() {
    cat <<'EOF'
1) 安装 Docker
2) 安装 Docker Compose 插件
3) 查看 Docker 引擎状态
4) 查看容器状态
5) 查看容器日志
6) 清理 Docker 垃圾
0) 返回上级菜单
EOF
}

module_docker_menu() {
    while true; do
        clear_screen
        print_section "Docker 与服务环境"
        docker_render_menu
        read -r -p "请输入选项: " choice
        case "${choice}" in
            1) docker_install_engine ;;
            2) docker_install_compose ;;
            3) docker_show_engine_status ;;
            4) docker_show_containers ;;
            5) docker_show_logs ;;
            6) docker_prune ;;
            0) return 0 ;;
            *) invalid_choice ;;
        esac
    done
}
