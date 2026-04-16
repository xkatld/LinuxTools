#!/usr/bin/env bash
set -euo pipefail

system_show_info() {
    clear_screen
    print_section "系统概况"
    show_os_summary
    echo "内核: $(uname -r)"
    echo "架构: $(uname -m)"
    echo "启动时间: $(uptime -p 2>/dev/null || true)"
    echo "当前时间: $(date '+%Y-%m-%d %H:%M:%S %Z')"
    echo "负载: $(uptime | awk -F'load average:' '{print $2}' | xargs 2>/dev/null || true)"
    echo
    echo "内存:"
    free -h 2>/dev/null || true
    echo
    echo "磁盘:"
    df -h / 2>/dev/null || true
    echo
    echo "IP:"
    hostname -I 2>/dev/null || true
    pause_enter
}

system_sync_time() {
    require_root || return 1
    print_section "同步上海时间"
    if command -v timedatectl >/dev/null 2>&1; then
        run_cmd timedatectl set-timezone Asia/Shanghai
        run_cmd timedatectl set-ntp true || true
        timedatectl status --no-pager | sed -n '1,8p'
        log_ok "时区已设置为 Asia/Shanghai。"
    else
        ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime
        log_ok "已链接时区文件到 Asia/Shanghai。"
    fi
    pause_enter
}

system_update_packages() {
    require_root || return 1
    print_section "更新系统软件包"
    ensure_os_detected
    update_package_index
    case "${PKG_MANAGER}" in
        apt) run_cmd apt-get upgrade -y ;;
        yum) run_cmd yum update -y ;;
        dnf) run_cmd dnf upgrade -y ;;
        apk) run_cmd apk upgrade ;;
        *) log_error "暂不支持当前系统。"; return 1 ;;
    esac
    log_ok "系统更新完成。"
    pause_enter
}

system_install_common_tools() {
    require_root || return 1
    print_section "安装常用工具集"
    ensure_os_detected
    case "${PKG_MANAGER}" in
        apt) install_packages curl wget git vim htop lsof unzip jq ca-certificates gnupg ;;
        yum|dnf) install_packages curl wget git vim htop lsof unzip jq ca-certificates gnupg2 ;;
        apk) install_packages curl wget git vim htop lsof unzip jq ca-certificates gnupg ;;
        *) log_error "暂不支持当前系统。"; return 1 ;;
    esac
    log_ok "常用工具安装完成。"
    pause_enter
}

system_change_hostname() {
    require_root || return 1
    print_section "修改主机名"
    read -r -p "请输入新的主机名: " new_hostname
    [[ -n "${new_hostname}" ]] || { log_error "主机名不能为空。"; pause_enter; return 1; }
    if command -v hostnamectl >/dev/null 2>&1; then
        run_cmd hostnamectl set-hostname "${new_hostname}"
    else
        echo "${new_hostname}" > /etc/hostname
        run_cmd hostname "${new_hostname}"
    fi
    log_ok "主机名已修改为 ${new_hostname}。"
    pause_enter
}

system_create_sudo_user() {
    require_root || return 1
    print_section "创建 sudo 用户"
    read -r -p "请输入用户名: " username
    [[ -n "${username}" ]] || { log_error "用户名不能为空。"; pause_enter; return 1; }
    if id "${username}" >/dev/null 2>&1; then
        log_warn "用户 ${username} 已存在。"
    else
        run_cmd useradd -m -s /bin/bash "${username}"
        log_ok "用户 ${username} 已创建。"
    fi
    passwd "${username}"
    if getent group sudo >/dev/null 2>&1; then
        run_cmd usermod -aG sudo "${username}"
    elif getent group wheel >/dev/null 2>&1; then
        run_cmd usermod -aG wheel "${username}"
    fi
    log_ok "用户 ${username} 已加入管理员组。"
    pause_enter
}

module_system_menu() {
    while true; do
        clear_screen
        print_section "系统基础管理"
        cat <<'EOF'
1) 查看系统概况
2) 同步上海时间
3) 更新系统软件包
4) 安装常用工具集
5) 修改主机名
6) 创建 sudo 用户
0) 返回上级菜单
EOF
        read -r -p "请输入选项: " choice
        case "${choice}" in
            1) system_show_info ;;
            2) system_sync_time ;;
            3) system_update_packages ;;
            4) system_install_common_tools ;;
            5) system_change_hostname ;;
            6) system_create_sudo_user ;;
            0) return 0 ;;
            *) invalid_choice ;;
        esac
    done
}
