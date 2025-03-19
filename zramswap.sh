#!/usr/bin/env bash

GREEN="\033[32m"
RESET="\033[0m"
RED="\033[31m"

verify_root_access() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}错误：此脚本需要 root 权限。${RESET}"
        exit 1
    fi
}

check_virtualization() {
    if [[ -d "/proc/vz" ]]; then
        echo -e "${RED}不支持：脚本不适用于基于 OpenVZ 的 VPS。${RESET}"
        exit 1
    fi
}

install_zram_tools() {
    if ! command -v zramctl &> /dev/null; then
        echo -e "${GREEN}正在安装 zram-tools...${RESET}"
        apt update && apt install -y zram-tools
    fi
}

configure_zram() {
    echo -e "${GREEN}请输入 Zram 交换大小（推荐：物理内存的 50%）${RESET}"
    read -p "请输入 Zram 交换大小（MB）: " zram_size

    if [[ -z "$zram_size" || ! "$zram_size" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}输入无效，请输入一个正整数。${RESET}"
        return 1
    fi

    echo -e "${GREEN}正在配置 Zram...${RESET}"
    echo "ALLOCATION_RATIO=$((zram_size * 2))" > /etc/default/zramswap
    echo "COMP_ALG=zstd" >> /etc/default/zramswap
    systemctl enable --now zramswap.service

    echo -e "${GREEN}Zram 交换已启用，当前配置如下：${RESET}"
    swapon --summary
}

remove_zram() {
    echo -e "${GREEN}正在移除 Zram 交换...${RESET}"
    systemctl stop zramswap.service
    systemctl disable zramswap.service
    rm -f /etc/default/zramswap

    echo -e "${GREEN}Zram 交换已成功禁用。${RESET}"
}

display_menu() {
    verify_root_access
    check_virtualization
    install_zram_tools

    clear
    echo -e "———————————————————————————————————————"
    echo -e "${GREEN}Linux VPS Zram 交换管理脚本${RESET}"
    echo -e "${GREEN}1. 添加 Zram 交换${RESET}"
    echo -e "${GREEN}2. 移除 Zram 交换${RESET}"
    echo -e "———————————————————————————————————————"
    
    read -p "请选择选项 [1-2]: " choice
    case "$choice" in
        1) configure_zram ;;
        2) remove_zram ;;
        *)
            echo -e "${GREEN}无效选项。请选择 1 或 2。${RESET}"
            sleep 2s
            display_menu
            ;;
    esac
}

display_menu
