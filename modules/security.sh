#!/usr/bin/env bash
set -euo pipefail

SSH_CONFIG_FILE=""
SSH_SERVICE_NAME=""

security_detect_ssh() {
    SSH_CONFIG_FILE="/etc/ssh/sshd_config"
    if command -v systemctl >/dev/null 2>&1; then
        if systemctl list-unit-files 2>/dev/null | grep -q '^ssh\.service'; then
            SSH_SERVICE_NAME="ssh"
        else
            SSH_SERVICE_NAME="sshd"
        fi
    else
        SSH_SERVICE_NAME="sshd"
    fi
}

security_backup_ssh_config() {
    backup_file "${SSH_CONFIG_FILE}"
}

security_set_ssh_option() {
    local key="$1"
    local value="$2"
    if grep -qE "^[# ]*${key}[[:space:]]+" "${SSH_CONFIG_FILE}"; then
        sed -i -E "s|^[# ]*${key}[[:space:]]+.*|${key} ${value}|" "${SSH_CONFIG_FILE}"
    else
        echo "${key} ${value}" >> "${SSH_CONFIG_FILE}"
    fi
}

security_validate_restart_ssh() {
    if command -v sshd >/dev/null 2>&1; then
        sshd -t
    fi
    if command -v systemctl >/dev/null 2>&1; then
        run_cmd systemctl restart "${SSH_SERVICE_NAME}"
        run_cmd systemctl enable "${SSH_SERVICE_NAME}" || true
    else
        service "${SSH_SERVICE_NAME}" restart
    fi
    log_ok "SSH 配置已生效。"
}

security_verify_ssh_listening_port() {
    local port="$1"
    if command -v ss >/dev/null 2>&1; then
        ss -tlnp 2>/dev/null | grep -Eq "[:.]${port}[[:space:]]"
    elif command -v netstat >/dev/null 2>&1; then
        netstat -tln 2>/dev/null | grep -Eq "[:.]${port}[[:space:]]"
    else
        log_warn "未找到 ss 或 netstat，跳过 SSH 监听端口验证。"
        return 0
    fi
}

security_restore_ssh_config() {
    local backup_path="$1"
    [[ -f "${backup_path}" ]] || return 1
    cp -f "${backup_path}" "${SSH_CONFIG_FILE}"
    log_warn "已恢复 SSH 配置备份：${backup_path}"
}

security_show_summary() {
    clear_screen
    print_section "SSH 当前配置摘要"
    security_detect_ssh
    grep -E '^(Port|PermitRootLogin|PasswordAuthentication|PubkeyAuthentication)' "${SSH_CONFIG_FILE}" 2>/dev/null || true
    echo
    ss -tlnp 2>/dev/null | grep -E ':(22|[1-9][0-9]{1,4}) ' | grep ssh || true
    pause_enter
}

security_change_ssh_port() {
    require_root || return 1
    security_detect_ssh
    print_section "修改 SSH 端口"
    read -r -p "请输入新的 SSH 端口: " new_port
    [[ "${new_port}" =~ ^[0-9]+$ ]] || { log_error "端口格式不正确。"; pause_enter; return 1; }
    [[ "${new_port}" -ge 1 && "${new_port}" -le 65535 ]] || { log_error "端口范围必须是 1-65535。"; pause_enter; return 1; }
    confirm_action "确认把 SSH 端口改为 ${new_port} 吗" || { log_warn "已取消。"; pause_enter; return 0; }

    local temp_backup
    temp_backup="$(mktemp)"
    cp -f "${SSH_CONFIG_FILE}" "${temp_backup}"

    security_backup_ssh_config
    security_set_ssh_option Port "${new_port}"
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q 'Status: active'; then
        ufw allow "${new_port}/tcp" || true
    elif command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld; then
        firewall-cmd --permanent --add-port="${new_port}/tcp" || true
        firewall-cmd --reload || true
    fi

    if ! security_validate_restart_ssh; then
        security_restore_ssh_config "${temp_backup}"
        security_validate_restart_ssh || true
        rm -f "${temp_backup}"
        log_error "SSH 重启失败，已恢复原配置。"
        pause_enter
        return 1
    fi

    if ! security_verify_ssh_listening_port "${new_port}"; then
        security_restore_ssh_config "${temp_backup}"
        security_validate_restart_ssh || true
        rm -f "${temp_backup}"
        log_error "未检测到 SSH 新端口 ${new_port} 监听，已恢复原配置。"
        pause_enter
        return 1
    fi

    rm -f "${temp_backup}"
    ss -tlnp 2>/dev/null | grep ":${new_port} " || true
    log_warn "如服务器存在安全组或外部防火墙，请确认已放行 ${new_port}/tcp。"
    pause_enter
}

security_toggle_root_login() {
    require_root || return 1
    security_detect_ssh
    print_section "切换 root 登录"
    read -r -p "请输入 on 或 off: " action
    case "${action}" in
        on) value="yes" ;;
        off) value="no" ;;
        *) log_error "请输入 on 或 off。"; pause_enter; return 1 ;;
    esac
    confirm_action "确认将 PermitRootLogin 改为 ${value} 吗" || { pause_enter; return 0; }
    security_backup_ssh_config
    security_set_ssh_option PermitRootLogin "${value}"
    security_validate_restart_ssh
    pause_enter
}

security_toggle_password_auth() {
    require_root || return 1
    security_detect_ssh
    print_section "切换密码登录"
    read -r -p "请输入 on 或 off: " action
    case "${action}" in
        on) value="yes" ;;
        off) value="no" ;;
        *) log_error "请输入 on 或 off。"; pause_enter; return 1 ;;
    esac
    confirm_action "确认将 PasswordAuthentication 改为 ${value} 吗" || { pause_enter; return 0; }
    security_backup_ssh_config
    security_set_ssh_option PasswordAuthentication "${value}"
    security_set_ssh_option PubkeyAuthentication yes
    security_validate_restart_ssh
    pause_enter
}

security_add_ssh_key() {
    require_root || return 1
    print_section "添加 SSH 公钥"
    read -r -p "请输入目标用户名: " username
    read -r -p "请粘贴公钥: " public_key
    [[ -n "${username}" && -n "${public_key}" ]] || { log_error "用户名和公钥都不能为空。"; pause_enter; return 1; }
    local home_dir
    home_dir=$(eval echo "~${username}")
    [[ -d "${home_dir}" ]] || { log_error "用户目录不存在。"; pause_enter; return 1; }
    mkdir -p "${home_dir}/.ssh"
    chmod 700 "${home_dir}/.ssh"
    touch "${home_dir}/.ssh/authorized_keys"
    if ! grep -qxF "${public_key}" "${home_dir}/.ssh/authorized_keys"; then
        echo "${public_key}" >> "${home_dir}/.ssh/authorized_keys"
    fi
    chmod 600 "${home_dir}/.ssh/authorized_keys"
    chown -R "${username}:${username}" "${home_dir}/.ssh"
    log_ok "公钥已添加到 ${username}。"
    pause_enter
}

security_show_login_records() {
    clear_screen
    print_section "SSH 登录记录"
    last -a | head -n 20 || true
    pause_enter
}

security_install_fail2ban() {
    require_root || return 1
    print_section "安装 Fail2ban"
    ensure_os_detected
    case "${PKG_MANAGER}" in
        apt|yum|dnf) install_packages fail2ban ;;
        apk) install_packages fail2ban ;;
        *) log_error "暂不支持当前系统。"; pause_enter; return 1 ;;
    esac
    if command -v systemctl >/dev/null 2>&1; then
        run_cmd systemctl enable --now fail2ban
        run_cmd systemctl status fail2ban --no-pager | sed -n '1,8p' || true
    fi
    log_ok "Fail2ban 已安装。"
    pause_enter
}

security_render_menu() {
    cat <<'EOF'
1) 查看 SSH 当前配置摘要
2) 修改 SSH 端口
3) 开启/关闭 root 登录
4) 开启/关闭密码登录
5) 添加 SSH 公钥
6) 查看 SSH 登录记录
7) 安装 Fail2ban
0) 返回上级菜单
EOF
}

module_security_menu() {
    while true; do
        clear_screen
        print_section "SSH 与安全管理"
        security_render_menu
        read -r -p "请输入选项: " choice
        case "${choice}" in
            1) security_show_summary ;;
            2) security_change_ssh_port ;;
            3) security_toggle_root_login ;;
            4) security_toggle_password_auth ;;
            5) security_add_ssh_key ;;
            6) security_show_login_records ;;
            7) security_install_fail2ban ;;
            0) return 0 ;;
            *) invalid_choice ;;
        esac
    done
}
