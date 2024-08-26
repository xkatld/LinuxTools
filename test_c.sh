#!/bin/bash

# 函数：列出可用磁盘和分区
list_disks_and_partitions() {
    echo "可用的磁盘和分区："
    fdisk -l | grep -E "Disk /dev/|/dev/" | grep -v "Disk identifier"
}

# 函数：检查分区是否存在
partition_exists() {
    if [ -b "/dev/$1" ]; then
        return 0
    else
        return 1
    fi
}

# 函数：创建分区
create_partition() {
    local disk=$1
    echo "创建分区..."
    fdisk /dev/$disk <<EOF
n
p


w
EOF
    partprobe /dev/$disk
    sleep 2
}

# 函数：格式化分区
format_partition() {
    local partition=$1
    echo "格式化分区..."
    mkfs.ext4 -F /dev/$partition
}

# 函数：挂载分区
mount_partition() {
    local partition=$1
    local mount_point=$2
    echo "挂载分区..."
    mkdir -p $mount_point
    mount /dev/$partition $mount_point
    echo "/dev/$partition $mount_point ext4 defaults 0 2" >> /etc/fstab
    systemctl daemon-reload
}

# 函数：创建swap
create_swap() {
    local size=$1
    echo "创建swap文件..."
    fallocate -l ${size}G /swapfile
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile
    echo "/swapfile none swap sw 0 0" >> /etc/fstab
    echo "Swap 文件已创建并激活"
}

# 函数：删除swap
delete_swap() {
    if [ -f /swapfile ]; then
        echo "删除swap文件..."
        swapoff /swapfile
        rm /swapfile
        sed -i '/swapfile/d' /etc/fstab
        echo "Swap 文件已删除"
    else
        echo "未找到 swap 文件"
    fi
}

# 函数：显示swap状态
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
    echo "2) 管理swap"
    echo "3) 退出"
    read -p "请选择操作 (1-3): " choice

    case $choice in
        1)
            list_disks_and_partitions
            read -p "请输入要操作的磁盘名称 (如 vda): " disk
            if [ ! -b "/dev/$disk" ]; then
                echo "错误：指定的磁盘不存在"
                continue
            fi
            
            echo "警告：即将在 /dev/$disk 上创建新分区。这可能会影响现有数据。"
            read -p "是否继续？(y/n): " confirm
            if [ "$confirm" != "y" ]; then
                echo "操作已取消"
                continue
            fi
            
            create_partition $disk
            
            new_partition=$(fdisk -l /dev/$disk | tail -n 1 | awk '{print $1}')
            format_partition $new_partition
            
            read -p "请输入挂载点 (如 /mnt/data，留空则自动生成): " mount_point
            if [ -z "$mount_point" ]; then
                mount_point="/mnt/data_$(date +%Y%m%d_%H%M%S)"
            fi
            mount_partition $new_partition $mount_point
            echo "新分区 $new_partition 已创建并挂载到 $mount_point"
            ;;
        2)
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
        3)
            echo "退出脚本"
            exit 0
            ;;
        *)
            echo "无效选项，请重新选择"
            ;;
    esac
done
