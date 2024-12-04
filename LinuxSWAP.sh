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

create_swap() {
    echo -e "${GREEN}请输入交换分区大小（推荐：系统内存的2倍）${RESET}"
    read -p "请输入交换分区大小（MB）：" swap_size

    if grep -q "swapfile" /etc/fstab; then
        echo -e "${RED}交换文件已存在。请在创建新的交换分区之前删除现有的交换分区。${RESET}"
        return 1
    fi

    echo -e "${GREEN}正在创建交换文件...${RESET}"
    fallocate -l "${swap_size}"M /swapfile
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile
    echo '/swapfile none swap defaults 0 0' >> /etc/fstab

    echo -e "${GREEN}交换配置如下：${RESET}"
    cat /proc/swaps
    cat /proc/meminfo | grep Swap
}

remove_swap() {
    if ! grep -q "swapfile" /etc/fstab; then
        echo -e "${RED}未找到交换文件。${RESET}"
        return 1
    fi

    echo -e "${GREEN}正在移除交换文件...${RESET}"
    sed -i '/swapfile/d' /etc/fstab
    echo 3 > /proc/sys/vm/drop_caches
    swapoff -a
    rm -f /swapfile

    echo -e "${GREEN}交换分区已成功删除。${RESET}"
}

display_menu() {
    verify_root_access
    check_virtualization

    clear
    echo -e "———————————————————————————————————————"
    echo -e "${GREEN}Linux VPS 交换分区管理脚本${RESET}"
    echo -e "${GREEN}1. 添加交换分区${RESET}"
    echo -e "${GREEN}2. 移除交换分区${RESET}"
    echo -e "———————————————————————————————————————"
    
    read -p "请选择选项 [1-2]: " choice
    case "$choice" in
        1) create_swap ;;
        2) remove_swap ;;
        *)
            echo -e "${GREEN}无效选项。请选择1或2。${RESET}"
            sleep 2s
            display_menu
            ;;
    esac
}

display_menu
