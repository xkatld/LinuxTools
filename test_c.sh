#!/bin/bash

# 函数：列出可用磁盘
list_available_disks() {
    echo "可用的磁盘："
    lsblk -d -n -o NAME,SIZE,TYPE | grep disk
}

# 函数：创建分区
create_partition() {
    local disk=$1
    local size=$2
    echo "创建分区..."
    sudo parted /dev/$disk --script mkpart primary ext4 0% $size
    sudo partprobe /dev/$disk
}

# 函数：格式化分区
format_partition() {
    local partition=$1
    echo "格式化分区..."
    sudo mkfs.ext4 /dev/$partition
}

# 函数：挂载分区
mount_partition() {
    local partition=$1
    local mount_point=$2
    echo "挂载分区..."
    sudo mkdir -p $mount_point
    sudo mount /dev/$partition $mount_point
    echo "/dev/$partition $mount_point ext4 defaults 0 2" | sudo tee -a /etc/fstab
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
    echo "1) 创建和挂载硬盘分区"
    echo "2) 管理swap"
    echo "3) 退出"
    read -p "请选择操作 (1-3): " choice

    case $choice in
        1)
            list_available_disks
            read -p "请输入要分区的磁盘名称 (如 sdb): " disk
            read -p "请输入分区大小 (如 20G, 50%, 100%FREE): " size
            create_partition $disk $size
            partition="${disk}1"  # 假设新创建的分区是第一个分区
            format_partition $partition
            read -p "请输入挂载点 (如 /mnt/data，留空则自动生成): " mount_point
            if [ -z "$mount_point" ]; then
                mount_point="/mnt/data_$(date +%Y%m%d_%H%M%S)"
            fi
            mount_partition $partition $mount_point
            echo "分区已创建并挂载到 $mount_point"
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
