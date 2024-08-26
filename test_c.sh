#!/bin/bash

# 函数：列出可用磁盘和分区
list_disks_and_partitions() {
    echo "可用的磁盘和分区："
    lsblk -o NAME,SIZE,TYPE,MOUNTPOINT,FSTYPE
    echo ""
    echo "未分配空间："
    parted -l | grep "Free Space"
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
    local start=$2
    local end=$3
    echo "创建分区..."
    sudo parted /dev/$disk --script mkpart primary ${start} ${end}
    sudo partprobe /dev/$disk
    sleep 2
}

# 函数：格式化分区
format_partition() {
    local partition=$1
    echo "格式化分区..."
    sudo mkfs.ext4 -F /dev/$partition
}

# 函数：挂载分区
mount_partition() {
    local partition=$1
    local mount_point=$2
    echo "挂载分区..."
    sudo mkdir -p $mount_point
    sudo mount /dev/$partition $mount_point
    echo "/dev/$partition $mount_point ext4 defaults 0 2" | sudo tee -a /etc/fstab
    sudo systemctl daemon-reload
}

# 函数：获取未分配空间
get_free_space() {
    local disk=$1
    parted /dev/$disk print free | awk '/Free Space/ {print $1 " " $2}'
}

# 函数：创建swap
create_swap() {
    local size=$1
    echo "创建swap文件..."
    sudo fallocate -l ${size}G /swapfile
    sudo chmod 600 /swapfile
    sudo mkswap /swapfile
    sudo swapon /swapfile
    echo "/swapfile none swap sw 0 0" | sudo tee -a /etc/fstab
    echo "Swap 文件已创建并激活"
}

# 函数：删除swap
delete_swap() {
    if [ -f /swapfile ]; then
        echo "删除swap文件..."
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
            
            free_space=$(get_free_space $disk)
            if [ -z "$free_space" ]; then
                echo "错误：该磁盘没有未分配空间"
                continue
            fi
            
            echo "可用的未分配空间："
            echo "$free_space"
            read -p "请输入新分区的起始位置: " start
            read -p "请输入新分区的结束位置（或输入100%使用所有剩余空间）: " end
            
            create_partition $disk $start $end
            
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
