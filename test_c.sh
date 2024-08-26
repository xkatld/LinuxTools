#!/bin/bash

# 函数：列出可用磁盘和分区
list_disks_and_partitions() {
    echo "可用的磁盘和分区："
    lsblk -o NAME,SIZE,TYPE,MOUNTPOINT,FSTYPE
    echo ""
    echo "LVM 信息："
    sudo pvs
    sudo vgs
    sudo lvs
}

# 函数：检查是否有未分配空间
check_free_space() {
    local disk=$1
    local free_space=$(sudo parted /dev/$disk unit GB print free | awk '/Free Space/ {gsub("GB",""); print $3}' | tail -n1)
    echo "$free_space"
}

# 函数：获取下一个可用的分区号
get_next_partition_number() {
    local disk=$1
    local last_partition=$(lsblk -nlo NAME /dev/$disk | tail -n1 | grep -o '[0-9]*$')
    echo $((last_partition + 1))
}

# 函数：创建分区
create_partition() {
    local disk=$1
    local size=$2
    local start=$(sudo parted /dev/$disk unit GB print free | awk '/Free Space/ {print $1}' | tail -n1)
    echo "创建分区..."
    sudo parted /dev/$disk --script mkpart primary ${start} ${size}GB
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
            
            free_space=$(check_free_space $disk)
            if (( $(echo "$free_space < 1" | bc -l) )); then
                echo "错误：该磁盘没有足够的未分配空间（小于 1GB）"
                continue
            fi
            
            echo "可用的未分配空间: ${free_space}GB"
            read -p "请输入新分区的大小（GB，最大 ${free_space}GB）: " size
            
            if (( $(echo "$size > $free_space" | bc -l) )); then
                echo "错误：指定的大小超过了可用空间"
                continue
            fi
            
            next_partition_number=$(get_next_partition_number $disk)
            new_partition="${disk}${next_partition_number}"
            
            echo "警告：即将在 /dev/$disk 上创建新分区 /dev/$new_partition。"
            read -p "是否继续？(y/n): " confirm
            if [ "$confirm" != "y" ]; then
                echo "操作已取消"
                continue
            fi
            
            create_partition $disk $size
            
            if [ ! -b "/dev/$new_partition" ]; then
                echo "错误：新分区 /dev/$new_partition 未成功创建"
                continue
            fi
            
            format_partition $new_partition
            
            read -p "请输入挂载点 (如 /mnt/data，留空则自动生成): " mount_point
            if [ -z "$mount_point" ]; then
                mount_point="/mnt/data_$(date +%Y%m%d_%H%M%S)"
            fi
            mount_partition $new_partition $mount_point
            echo "新分区 $new_partition 已创建并挂载到 $mount_point"
            ;;
        2)
            # Swap 管理代码（此处省略）
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
