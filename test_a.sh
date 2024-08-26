#!/bin/bash

# 函数：检查命令是否存在
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# 关闭 SELinux
disable_selinux() {
    if [ -f /etc/selinux/config ]; then
        sudo sed -i 's/SELINUX=enforcing/SELINUX=disabled/' /etc/selinux/config
        sudo setenforce 0
        echo "SELinux 已禁用。需要重启以完全生效。"
    else
        echo "未检测到 SELinux 配置文件。"
    fi
}

# 关闭防火墙
disable_firewall() {
    if command_exists firewall-cmd; then
        # CentOS 7+, Fedora
        sudo systemctl stop firewalld
        sudo systemctl disable firewalld
        echo "FirewallD 已关闭并禁用。"
    elif command_exists ufw; then
        # Ubuntu, Debian
        sudo ufw disable
        echo "UFW 防火墙已禁用。"
    elif command_exists iptables; then
        # 通用 Linux
        sudo iptables -F
        sudo iptables-save | sudo tee /etc/sysconfig/iptables
        echo "iptables 规则已清空。"
    else
        echo "未检测到已知的防火墙服务。"
    fi
}

# 同步时间到上海时区
sync_time() {
    if command_exists timedatectl; then
        sudo timedatectl set-timezone Asia/Shanghai
        sudo timedatectl set-ntp true
        echo "系统时区已设置为上海，并启用了 NTP 同步。"
    else
        sudo ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime
        if command_exists ntpdate; then
            sudo ntpdate time.asia.apple.com
        elif command_exists chronyd; then
            sudo chronyd -q 'server time.asia.apple.com iburst'
        fi
        echo "系统时区已设置为上海，并尝试同步时间。"
    fi
}

# 主菜单
while true; do
    echo "请选择要执行的操作："
    echo "1) 关闭 SELinux"
    echo "2) 关闭防火墙"
    echo "3) 同步时间到上海时区"
    echo "4) 执行所有操作"
    echo "5) 退出"
    read -p "请输入选项 (1-5): " choice

    case $choice in
        1) disable_selinux ;;
        2) disable_firewall ;;
        3) sync_time ;;
        4) 
            disable_selinux
            disable_firewall
            sync_time
            ;;
        5) 
            echo "退出脚本。"
            exit 0
            ;;
        *)
            echo "无效选项，请重新选择。"
            ;;
    esac

    echo ""
done
