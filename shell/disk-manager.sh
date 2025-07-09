#!/bin/bash
#
# +--------------------------------------------------------------------+
# | Script Name:    Disk Partition Manager (v1.1)                      |
# | Author:         xkatld & gemini                                    |
# | Description:    一个用于Linux硬盘分区、挂载和fstab管理的工具。     |
# | Original File:  test_c.sh                                          |
# +--------------------------------------------------------------------+

# --- 安全设置 ---
set -o errexit
set -o nounset
set -o pipefail

# --- 颜色定义 ---
readonly COLOR_GREEN='\033[0;32m'
readonly COLOR_RED='\033[0;31m'
readonly COLOR_YELLOW='\033[1;33m'
readonly COLOR_CYAN='\033[0;36m'
readonly COLOR_NC='\033[0m'

# --- 消息函数 ---
msg_info() { echo -e "${COLOR_CYAN}[*] $1${COLOR_NC}"; }
msg_ok() { echo -e "${COLOR_GREEN}[+] $1${COLOR_NC}"; }
msg_error() { echo -e "${COLOR_RED}[!] 错误: $1${COLOR_NC}" >&2; }
msg_warn() { echo -e "${COLOR_YELLOW}[-] 警告: $1${COLOR_NC}"; }

# --- 辅助函数 ---

check_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        msg_error "此脚本需要 root 权限来管理磁盘和系统配置。"
        exit 1
    fi
}

press_any_key() {
    echo
    read -n 1 -s -r -p "按任意键返回主菜单..."
}

# --- 核心功能 ---

create_and_mount_partition() {
    msg_info "正在扫描可用的块设备..."
    lsblk -d -o NAME,SIZE,TYPE | grep 'disk'
    echo
    read -p "请输入要操作的磁盘名称 (例如: vda, sdb): " disk
    local disk_path="/dev/$disk"

    if [[ -z "$disk" ]] || [[ ! -b "$disk_path" ]]; then
        msg_error "指定的磁盘 '$disk_path' 不存在或无效。"
        return
    fi

    msg_warn "即将在 '$disk_path' 上创建一个新的主分区，并使用所有剩余空间。"
    read -p "是否继续? (y/N): " confirm
    if [[ ! "$confirm" =~ ^[yY]$ ]]; then
        msg_info "操作已取消。"
        return
    fi
    
    msg_info "正在使用 fdisk 创建分区..."
    if ! (echo n; echo p; echo; echo; echo; echo w) | fdisk "$disk_path"; then
        msg_error "fdisk 创建分区失败。"
        return
    fi

    partprobe "$disk_path"
    sleep 2 # 等待内核识别新分区

    local new_partition
    new_partition=$(lsblk -nlo NAME "$disk_path" | tail -n1)
    local new_partition_path="/dev/$new_partition"

    if [[ ! -b "$new_partition_path" ]]; then
        msg_error "未能检测到新创建的分区。请手动检查 'lsblk' 的输出。"
        return
    fi
    msg_ok "成功创建分区: $new_partition_path"

    read -p "请输入挂载点 (例如 /data，留空将自动生成): " mount_point
    if [[ -z "$mount_point" ]]; then
        mount_point="/mnt/data_$(date +%s)"
    fi

    if [[ ! -d "$mount_point" ]]; then
        mkdir -p "$mount_point"
    fi

    msg_info "正在格式化分区为 ext4..."
    if ! mkfs.ext4 -F "$new_partition_path"; then
        msg_error "格式化分区失败。"
        return
    fi
    
    msg_info "正在挂载分区到 $mount_point..."
    if ! mount "$new_partition_path" "$mount_point"; then
        msg_error "挂载失败。"
        return
    fi
    
    msg_info "正在将挂载信息写入 /etc/fstab..."
    echo "$new_partition_path $mount_point ext4 defaults 0 2" >> /etc/fstab
    systemctl daemon-reload

    msg_ok "分区 $new_partition_path 已成功创建、格式化并挂载到 $mount_point！"
}

delete_partition() {
    msg_info "当前分区列表:"
    lsblk -nlo NAME,SIZE,MOUNTPOINT | grep -v 'disk'
    echo
    read -p "请输入要删除的分区名称 (例如: vda1, sdb1): " partition
    local partition_path="/dev/$partition"

    if [[ -z "$partition" ]] || [[ ! -b "$partition_path" ]]; then
        msg_error "指定的分区 '$partition_path' 不存在或无效。"
        return
    fi

    local disk_name=${partition//[0-9]/}
    local part_num=${partition//[^0-9]/}
    local disk_path="/dev/$disk_name"

    msg_warn "!!! 危险操作 !!!"
    msg_warn "此操作将卸载分区，从fstab移除记录，并永久删除分区 '$partition' 及其上的所有数据！"
    read -p "请再次确认是否继续? (y/N): " confirm
    if [[ ! "$confirm" =~ ^[yY]$ ]]; then
        msg_info "操作已取消。"
        return
    fi

    msg_info "正在卸载分区..."
    umount "$partition_path" 2>/dev/null || msg_warn "分区未挂载或卸载失败，将继续操作。"
    
    msg_info "正在从 /etc/fstab 中移除记录..."
    sed -i.bak "\|^${partition_path}|d" /etc/fstab

    msg_info "正在使用 fdisk 删除分区..."
    if ! (echo d; echo "$part_num"; echo w) | fdisk "$disk_path"; then
        msg_error "fdisk 删除分区失败。"
        return
    fi

    partprobe "$disk_path"
    sleep 2

    msg_ok "分区 '$partition' 已成功删除。"
}

clean_fstab() {
    msg_info "正在检查 /etc/fstab 中的失效条目..."
    local temp_fstab
    temp_fstab=$(mktemp)
    local invalid_found=0

    # 使用更可靠的方式读取fstab，避免带有空格的挂载点路径出错
    while read -r device mount_point fstype options dump pass; do
        # 忽略注释和空行
        if [[ "$device" =~ ^# || -z "$device" ]]; then
            echo "$device $mount_point $fstype $options $dump $pass" >> "$temp_fstab"
            continue
        fi

        # 检查设备是否存在，对于UUID和LABEL需要特殊处理
        local device_exists=0
        if [[ $device == UUID=* ]]; then
            if blkid -U "${device#UUID=}" >/dev/null 2>&1; then
                device_exists=1
            fi
        elif [[ $device == LABEL=* ]]; then
            if blkid -L "${device#LABEL=}" >/dev/null 2>&1; then
                device_exists=1
            fi
        elif [ -b "$device" ]; then
            device_exists=1
        fi

        if [[ $device_exists -eq 1 ]]; then
            echo "$device $mount_point $fstype $options $dump $pass" >> "$temp_fstab"
        else
            msg_warn "发现失效条目: $device $mount_point"
            invalid_found=1
        fi
    done < /etc/fstab

    if [[ $invalid_found -eq 0 ]]; then
        msg_ok "未发现任何失效的 fstab 条目。"
        rm "$temp_fstab"
        return
    fi
    
    echo
    msg_warn "以上失效条目将被移除。这是预览："
    diff -u /etc/fstab "$temp_fstab" || true
    echo
    read -p "确认要应用更改吗? (原文件将备份为 /etc/fstab.bak) (y/N): " confirm
    if [[ "$confirm" =~ ^[yY]$ ]]; then
        cp /etc/fstab /etc/fstab.bak
        mv "$temp_fstab" /etc/fstab
        msg_ok "/etc/fstab 已更新。备份文件: /etc/fstab.bak"
    else
        msg_info "操作已取消。"
        rm "$temp_fstab"
    fi
}


# --- 主菜单 ---
main_menu() {
    while true; do
        clear
        echo -e "${COLOR_GREEN}========================================="
        echo -e "        硬盘分区管理工具 v1.1"
        echo -e "=========================================${COLOR_NC}"
        echo "  1) 创建并挂载新分区 (使用整块磁盘剩余空间)"
        echo "  2) 删除一个分区"
        echo "  3) 清理 /etc/fstab 中的失效条目"
        echo -e "  ${COLOR_RED}4) 退出脚本${COLOR_NC}"
        echo -e "${COLOR_GREEN}=========================================${COLOR_NC}"
        read -p "请选择操作 [1-4]: " choice

        case $choice in
            1) create_and_mount_partition ;;
            2) delete_partition ;;
            3) clean_fstab ;;
            4) msg_info "正在退出脚本..."; exit 0 ;;
            *) msg_error "无效选项，请重新选择。" ;;
        esac
        press_any_key
    done
}

# --- 脚本入口 ---
check_root
main_menu