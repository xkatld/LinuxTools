#!/usr/bin/env bash
set -euo pipefail

network_detect_dns_mode() {
    local resolv_conf="${1:-/etc/resolv.conf}"
    local resolved_dir="/etc/systemd/resolved.conf.d"
    if [[ -L "${resolv_conf}" ]]; then
        local target
        target="$(readlink -f "${resolv_conf}" 2>/dev/null || readlink "${resolv_conf}" 2>/dev/null || true)"
        if [[ "${target}" == *"/systemd/resolve/"* ]]; then
            echo "systemd-resolved"
            return 0
        fi
    fi
    if [[ "${resolv_conf}" == "/etc/resolv.conf" ]]; then
        if [[ -d "${resolved_dir}" ]] || command -v resolvectl >/dev/null 2>&1; then
            if command -v systemctl >/dev/null 2>&1 && systemctl is-enabled systemd-resolved >/dev/null 2>&1; then
                echo "systemd-resolved"
                return 0
            fi
        fi
    fi
    echo "plain"
}

network_write_plain_resolv_conf() {
    local dns1="$1"
    local dns2="$2"
    backup_file /etc/resolv.conf
    cat > /etc/resolv.conf <<EOF
nameserver ${dns1}
nameserver ${dns2}
EOF
}

network_write_systemd_resolved_dns() {
    local dns1="$1"
    local dns2="$2"
    local conf_dir="/etc/systemd/resolved.conf.d"
    local conf_file="${conf_dir}/99-linux-toolbox-dns.conf"
    mkdir -p "${conf_dir}"
    backup_file "${conf_file}"
    cat > "${conf_file}" <<EOF
[Resolve]
DNS=${dns1} ${dns2}
FallbackDNS=
EOF
    if command -v systemctl >/dev/null 2>&1; then
        run_cmd systemctl restart systemd-resolved
    fi
    if command -v resolvectl >/dev/null 2>&1; then
        resolvectl flush-caches >/dev/null 2>&1 || true
    fi
}

network_write_dns_restore_script() {
    local dns_mode="$1"
    local output_path="${2:-/tmp/linux-toolbox-restore-dns.sh}"
    local backup_file_path="${TOOLBOX_BACKUP_LAST_FILE:-}"
    cat > "${output_path}" <<EOF
#!/usr/bin/env bash
set -euo pipefail
EOF
    case "${dns_mode}" in
        plain)
            [[ -n "${backup_file_path}" ]] || { log_warn "未找到最近的 DNS 备份文件，跳过恢复脚本生成。"; return 1; }
            cat >> "${output_path}" <<EOF
cp -f "${backup_file_path}" /etc/resolv.conf
EOF
            ;;
        systemd-resolved)
            cat >> "${output_path}" <<'EOF'
rm -f /etc/systemd/resolved.conf.d/99-linux-toolbox-dns.conf
if command -v systemctl >/dev/null 2>&1; then
    systemctl restart systemd-resolved || true
fi
if command -v resolvectl >/dev/null 2>&1; then
    resolvectl flush-caches >/dev/null 2>&1 || true
fi
EOF
            ;;
        *)
            log_warn "未知 DNS 模式，跳过恢复脚本生成。"
            return 1
            ;;
    esac
    chmod +x "${output_path}"
    log_ok "已生成 DNS 恢复脚本：${output_path}"
}

network_restore_dns() {
    require_root || return 1
    local dns_mode
    dns_mode="$(network_detect_dns_mode /etc/resolv.conf)"
    case "${dns_mode}" in
        systemd-resolved)
            rm -f /etc/systemd/resolved.conf.d/99-linux-toolbox-dns.conf
            if command -v systemctl >/dev/null 2>&1; then
                run_cmd systemctl restart systemd-resolved
            fi
            if command -v resolvectl >/dev/null 2>&1; then
                resolvectl flush-caches >/dev/null 2>&1 || true
            fi
            ;;
        *)
            if [[ -n "${TOOLBOX_BACKUP_LAST_FILE:-}" && -f "${TOOLBOX_BACKUP_LAST_FILE}" ]]; then
                cp -f "${TOOLBOX_BACKUP_LAST_FILE}" /etc/resolv.conf
            else
                log_error "未找到最近的 DNS 备份文件，无法自动恢复。"
                pause_enter
                return 1
            fi
            ;;
    esac
    getent hosts github.com >/dev/null 2>&1 && log_ok "DNS 恢复完成，解析验证通过。" || log_warn "DNS 已恢复，但解析验证未通过。"
    pause_enter
}

network_summary() {
    clear_screen
    print_section "网络信息摘要"
    ip -brief address 2>/dev/null || ip addr 2>/dev/null || true
    echo
    ip route 2>/dev/null || true
    echo
    grep -E '^nameserver' /etc/resolv.conf 2>/dev/null || true
    pause_enter
}

network_change_dns() {
    require_root || return 1
    print_section "修改 DNS"
    read -r -p "首选 DNS [默认 223.5.5.5]: " dns1
    read -r -p "备用 DNS [默认 1.1.1.1]: " dns2
    dns1=${dns1:-223.5.5.5}
    dns2=${dns2:-1.1.1.1}
    confirm_action "确认将 DNS 改为 ${dns1} / ${dns2} 吗" || { pause_enter; return 0; }
    local dns_mode
    local restore_script="/tmp/linux-toolbox-restore-dns.sh"
    dns_mode="$(network_detect_dns_mode /etc/resolv.conf)"
    case "${dns_mode}" in
        systemd-resolved)
            network_write_systemd_resolved_dns "${dns1}" "${dns2}"
            ;;
        *)
            network_write_plain_resolv_conf "${dns1}" "${dns2}"
            ;;
    esac
    network_write_dns_restore_script "${dns_mode}" "${restore_script}" || true
    getent hosts github.com >/dev/null 2>&1 && log_ok "DNS 修改完成，解析验证通过。" || log_warn "DNS 已修改，但解析验证未通过。"
    log_info "DNS 配置模式: ${dns_mode}"
    log_info "如需回退，可执行：bash ${restore_script}"
    pause_enter
}

network_show_ports() {
    clear_screen
    print_section "监听端口"
    ss -tulpen 2>/dev/null || netstat -tulpen 2>/dev/null || true
    pause_enter
}

network_test_port() {
    print_section "测试端口连通性"
    read -r -p "目标主机 [默认 127.0.0.1]: " host
    read -r -p "目标端口: " port
    host=${host:-127.0.0.1}
    [[ -n "${port}" ]] || { log_error "端口不能为空。"; pause_enter; return 1; }
    if command -v nc >/dev/null 2>&1; then
        nc -zv -w 3 "${host}" "${port}"
    else
        timeout 3 bash -c "</dev/tcp/${host}/${port}" && echo "连接成功" || { log_error "连接失败"; pause_enter; return 1; }
    fi
    log_ok "端口测试完成。"
    pause_enter
}

network_check_mail_ports() {
    clear_screen
    print_section "检查本机邮件端口"
    for port in 25 465 587; do
        if ss -tln 2>/dev/null | grep -q ":${port} "; then
            echo "端口 ${port}: 已监听"
        else
            echo "端口 ${port}: 未监听"
        fi
    done
    pause_enter
}

network_show_bandwidth_connections() {
    clear_screen
    print_section "带宽占用连接（近似）"
    ss -tpn state established 2>/dev/null | head -n 30 || true
    pause_enter
}

network_enable_bbr() {
    require_root || return 1
    print_section "检查并启用 BBR"
    if sysctl net.ipv4.tcp_congestion_control 2>/dev/null | grep -q 'bbr'; then
        log_ok "BBR 已启用。"
        pause_enter
        return 0
    fi
    backup_file /etc/sysctl.conf
    grep -q 'net.core.default_qdisc=fq' /etc/sysctl.conf 2>/dev/null || echo 'net.core.default_qdisc=fq' >> /etc/sysctl.conf
    grep -q 'net.ipv4.tcp_congestion_control=bbr' /etc/sysctl.conf 2>/dev/null || echo 'net.ipv4.tcp_congestion_control=bbr' >> /etc/sysctl.conf
    run_cmd sysctl -p
    sysctl net.ipv4.tcp_congestion_control | tee /dev/stderr | grep -q 'bbr' && log_ok "BBR 已启用。" || log_warn "已写入配置，请确认内核是否支持 BBR。"
    pause_enter
}

module_network_menu() {
    while true; do
        clear_screen
        print_section "网络诊断与优化"
        cat <<'EOF'
1) 查看网络信息摘要
2) 修改 DNS
3) 恢复上次 DNS 配置
4) 查看监听端口
5) 测试指定端口连通性
6) 检查本机邮件端口
7) 查看带宽占用连接
8) 检查并启用 BBR
0) 返回上级菜单
EOF
        read -r -p "请输入选项: " choice
        case "${choice}" in
            1) network_summary ;;
            2) network_change_dns ;;
            3) network_restore_dns ;;
            4) network_show_ports ;;
            5) network_test_port ;;
            6) network_check_mail_ports ;;
            7) network_show_bandwidth_connections ;;
            8) network_enable_bbr ;;
            0) return 0 ;;
            *) invalid_choice ;;
        esac
    done
}
