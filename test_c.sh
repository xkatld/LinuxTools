#!/bin/bash

# 函数：检查是否有未分配空间
check_free_space() {
    local disk=$1
    local free_space=$(sudo parted /dev/$disk unit GB print free | awk '/Free Space/ {gsub("GB",""); print $3}' | tail -n1)
    echo "${free_space%.*}"  # 去掉小数部分
}

# 函数：创建分区
create_partition() {
    local disk=$1
    local size=$2
    local start=$(sudo parted /dev/$disk unit GB print free | awk '/Free Space/ {print $1}' | tail -n1)
    sudo parted /dev/$disk --script mkpart primary ${start} ${size}GB
    sudo partprobe /dev/$disk
    sleep 2
}

# 函数：格式化分区
format_partition() {
    local partition=$1
    sudo mkfs.ext4 -F /dev/$partition > /dev/null 2>&1
}

# 函数：挂载分区
mount_partition() {
    local partition=$1
    local mount_point=$2
    sudo mkdir -p $mount_point
    sudo mount /dev/$partition $mount_point
    echo "/dev/$partition $mount_point ext4 defaults 0 2" | sudo tee -a /etc/fstab > /dev/null
    sudo systemctl daemon-reload
}

# 函数：删除分区
delete_partition() {
    local partition=$1
    local mount_point=$(findmnt -n -o TARGET /dev/$partition)
    if [ -n "$mount_point" ]; then
        sudo umount $mount_point
        sudo sed -i "\|^/dev/$partition|d" /etc/fstab
    fi
    sudo parted /dev/${partition:0:3} --script rm ${partition:(-1)}
    sudo partprobe /dev/${partition:0:3}
}

# 函数：创建swap
create_swap() {
    local size=$1
    sudo fallocate -l ${size}G /swapfile
    sudo chmod 600 /swapfile
    sudo mkswap /swapfile
    sudo swapon /swapfile
    echo "/swapfile none swap sw 0 0" | sudo tee -a /etc/fstab > /dev/null
    echo "Swap 文件已创建并激活"
}

# 函数：删除swap
delete_swap() {
    if [ -f /swapfile ]; then
        sudo swapoff /swapfile
        sudo rm /swapfile
        sudo sed -i '/swapfile/d' /etc/fstab
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
    echo "2) 删除分区"
    echo "3) 管理swap"
    echo "4) 退出"
    read -p "请选择操作 (1-4): " choice

    case $choice in
        1)
            read -p "请输入要操作的磁盘名称 (如 vda): " disk
            if [ ! -b "/dev/$disk" ]; then
                echo "错误：指定的磁盘不存在"
                continue
            fi
            
            free_space=$(check_free_space $disk)
            echo "可用的未分配空间: ${free_space}GB"
            read -p "请输入新分区的大小（GB，最大 ${free_space}GB）: " size
            
            if [ $size -gt $free_space ]; then
                echo "错误：指定的大小超过了可用空间"
                continue
            fi
            
            create_partition $disk $size
            
            new_partition=$(lsblk -nlo NAME /dev/$disk | tail -n1)
            format_partition $new_partition
            
            read -p "请输入挂载点 (如 /mnt/data，留空则自动生成): " mount_point
            if [ -z "$mount_point" ]; then
                mount_point="/mnt/data_$(date +%Y%m%d_%H%M%S)"
            fi
            mount_partition $new_partition $mount_point
            echo "新分区 $new_partition 已创建并挂载到 $mount_point"
            ;;
        2)
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
