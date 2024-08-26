#!/bin/bash

create_partition() {
    local disk=$1
    (
    echo n # 新建分区
    echo p # 主分区
    echo   # 默认分区号
    echo   # 默认起始扇区
    echo   # 默认结束扇区（使用所有可用空间）
    echo w # 写入更改
    ) | fdisk /dev/$disk

    partprobe /dev/$disk
    sleep 2
}

format_and_mount() {
    local partition=$1
    local mount_point=$2

    mkfs.ext4 -F /dev/$partition
    mkdir -p $mount_point
    mount /dev/$partition $mount_point
    echo "/dev/$partition $mount_point ext4 defaults 0 2" >> /etc/fstab
    systemctl daemon-reload
}

delete_partition() {
    local partition=$1
    local disk=${partition:0:3}
    local part_num=${partition:3}

    umount /dev/$partition 2>/dev/null
    sed -i "\|^/dev/$partition|d" /etc/fstab

    (
    echo d # 删除分区
    echo $part_num # 分区号
    echo w # 写入更改
    ) | fdisk /dev/$disk

    partprobe /dev/$disk
    sleep 2
}

create_swap() {
    local size=$1
    fallocate -l ${size}G /swapfile
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile
    echo "/swapfile none swap sw 0 0" >> /etc/fstab
    echo "Swap 文件已创建并激活"
}

delete_swap() {
    if [ -f /swapfile ]; then
        swapoff /swapfile
        rm /swapfile
        sed -i '/swapfile/d' /etc/fstab
        echo "Swap 文件已删除"
    else
        echo "未找到 swap 文件"
    fi
}

show_swap_status() {
    echo "当前 Swap 状态："
    free -h | grep Swap
    if [ -f /swapfile ]; then
        echo "Swap 文件: /swapfile"
        ls -lh /swapfile
    else
        echo "未找到 swap 文件"
    fi
}

# 主菜单
while true; do
    echo "磁盘管理工具"
    echo "1) 创建和挂载硬盘分区"
    echo "2) 删除分区"
    echo "3) 管理swap"
    echo "4) 退出"
    read -p "请选择操作 (1-4): " choice

    case $choice in
        1)
            echo "可用的硬盘："
            lsblk -ndo NAME,SIZE,TYPE | grep disk
            read -p "请输入要操作的磁盘名称 (如 vda): " disk
            if [ ! -b "/dev/$disk" ]; then
                echo "错误：指定的磁盘不存在"
                continue
            fi
            create_partition $disk
            new_partition=$(lsblk -nlo NAME /dev/$disk | tail -n1)
            read -p "请输入挂载点 (如 /mnt/data，留空则自动生成): " mount_point
            if [ -z "$mount_point" ]; then
                mount_point="/mnt/data_$(date +%Y%m%d_%H%M%S)"
            fi
            format_and_mount $new_partition $mount_point
            echo "新分区 /dev/$new_partition 已创建并挂载到 $mount_point"
            ;;
        2)
            echo "当前分区："
            lsblk -nlo NAME,SIZE,MOUNTPOINT | grep -v "^[sl]"
            read -p "请输入要删除的分区名称 (如 vda3): " partition
            if [ ! -b "/dev/$partition" ]; then
                echo "错误：指定的分区不存在"
                continue
            fi
            delete_partition $partition
            echo "分区 $partition 已删除"
            ;;
        3)
            while true; do
                echo "Swap 管理："
                echo "  a) 创建 swap"
                echo "  b) 删除 swap"
                echo "  c) 显示 swap 状态"
                echo "  d) 返回主菜单"
                read -p "请选择操作 (a-d): " swap_choice
                case $swap_choice in
                    a)
                        read -p "请输入要创建的swap大小（GB）: " swap_size
                        create_swap $swap_size
                        ;;
                    b)
                        delete_swap
                        ;;
                    c)
                        show_swap_status
                        ;;
                    d)
                        break
                        ;;
                    *)
                        echo "无效选项，请重新选择"
                        ;;
                esac
            done
            ;;
        4)
            echo "退出脚本"
            exit 0
            ;;
        *)
            echo "无效选项，请重新选择"
            ;;
    esac
done
