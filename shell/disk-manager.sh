#!/bin/bash

set -euo pipefail

log_info() { echo "[INFO] $1"; }
log_ok() { echo "[OK] $1"; }
log_error() { echo "[ERROR] $1" >&2; }
log_warn() { echo "[WARN] $1"; }

check_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        log_error "需要 root 权限"
        exit 1
    fi
}

create_and_mount_partition() {
    log_info "扫描可用磁盘..."
    lsblk -d -o NAME,SIZE,TYPE | grep 'disk'
    echo
    read -p "磁盘名称 (如 vda, sdb): " -r disk
    local disk_path="/dev/$disk"

    if [[ -z "$disk" ]] || [[ ! -b "$disk_path" ]]; then
        log_error "磁盘不存在: $disk_path"
        return
    fi

    log_warn "将在 '$disk_path' 创建新分区"
    read -p "是否继续? [y/N]: " -r confirm
    confirm=${confirm:-N}
    if [[ ! "$confirm" =~ ^[yY]$ ]]; then
        log_info "已取消"
        return
    fi
    
    log_info "创建分区..."
    if ! (echo n; echo p; echo; echo; echo; echo w) | fdisk "$disk_path"; then
        log_error "创建分区失败"
        return
    fi

    partprobe "$disk_path"
    sleep 2

    local new_partition
    new_partition=$(lsblk -nlo NAME "$disk_path" | tail -n1)
    local new_partition_path="/dev/$new_partition"

    if [[ ! -b "$new_partition_path" ]]; then
        log_error "未检测到新分区"
        return
    fi
    log_ok "分区已创建: $new_partition_path"

    read -p "挂载点 (如 /data) [默认: /mnt/data_自动]: " -r mount_point
    if [[ -z "$mount_point" ]]; then
        mount_point="/mnt/data_$(date +%s)"
    fi

    if [[ ! -d "$mount_point" ]]; then
        mkdir -p "$mount_point"
    fi

    log_info "格式化为 ext4..."
    if ! mkfs.ext4 -F "$new_partition_path"; then
        log_error "格式化失败"
        return
    fi
    
    log_info "挂载到 $mount_point..."
    if ! mount "$new_partition_path" "$mount_point"; then
        log_error "挂载失败"
        return
    fi
    
    log_info "写入 /etc/fstab..."
    echo "$new_partition_path $mount_point ext4 defaults 0 2" >> /etc/fstab
    systemctl daemon-reload

    log_ok "分区 $new_partition_path 已挂载到 $mount_point"
}

delete_partition() {
    log_info "当前分区:"
    lsblk -nlo NAME,SIZE,MOUNTPOINT | grep -v 'disk'
    echo
    read -p "要删除的分区 (如 vda1): " -r partition
    local partition_path="/dev/$partition"

    if [[ -z "$partition" ]] || [[ ! -b "$partition_path" ]]; then
        log_error "分区不存在: $partition_path"
        return
    fi

    local disk_name=${partition//[0-9]/}
    local part_num=${partition//[^0-9]/}
    local disk_path="/dev/$disk_name"

    log_warn "!!! 危险操作 !!!"
    log_warn "将删除分区 '$partition' 及其所有数据"
    read -p "确认删除? [y/N]: " -r confirm
    confirm=${confirm:-N}
    if [[ ! "$confirm" =~ ^[yY]$ ]]; then
        log_info "已取消"
        return
    fi

    log_info "卸载分区..."
    umount "$partition_path" 2>/dev/null || log_warn "分区未挂载"
    
    log_info "从 /etc/fstab 移除..."
    sed -i.bak "\|^${partition_path}|d" /etc/fstab

    log_info "删除分区..."
    if ! (echo d; echo "$part_num"; echo w) | fdisk "$disk_path"; then
        log_error "删除分区失败"
        return
    fi

    partprobe "$disk_path"
    sleep 2

    log_ok "分区 '$partition' 已删除"
}

clean_fstab() {
    log_info "检查 /etc/fstab 失效条目..."
    local temp_fstab
    temp_fstab=$(mktemp)
    local invalid_found=0

    while read -r device mount_point fstype options dump pass; do
        if [[ "$device" =~ ^# || -z "$device" ]]; then
            echo "$device $mount_point $fstype $options $dump $pass" >> "$temp_fstab"
            continue
        fi

        local device_exists=0
        if [[ $device == UUID=* ]]; then
            if blkid -U "${device#UUID=}" >/dev/null 2>&1; then
                device_exists=1
            fi
        elif [[ $device == LABEL=* ]]; then
            if blkid -L "${device#LABEL=}" >/dev/null 2>&1; then
                device_exists=1
            fi
        elif [[ -b "$device" ]]; then
            device_exists=1
        fi

        if [[ $device_exists -eq 1 ]]; then
            echo "$device $mount_point $fstype $options $dump $pass" >> "$temp_fstab"
        else
            log_warn "失效条目: $device $mount_point"
            invalid_found=1
        fi
    done < /etc/fstab

    if [[ $invalid_found -eq 0 ]]; then
        log_ok "未发现失效条目"
        rm "$temp_fstab"
        return
    fi
    
    echo
    log_warn "以下失效条目将被移除:"
    diff -u /etc/fstab "$temp_fstab" || true
    echo
    read -p "确认应用更改? [Y/n]: " -r confirm
    confirm=${confirm:-Y}
    if [[ "$confirm" =~ ^[yY]$ ]]; then
        cp /etc/fstab /etc/fstab.bak
        mv "$temp_fstab" /etc/fstab
        log_ok "/etc/fstab 已更新，备份: /etc/fstab.bak"
    else
        log_info "已取消"
        rm "$temp_fstab"
    fi
}

main_menu() {
    while true; do
        clear 2>/dev/null || printf '\033[2J\033[H'
        echo "========================================"
        echo "  硬盘分区管理工具"
        echo "========================================"
        echo "  1) 创建并挂载新分区"
        echo "  2) 删除分区"
        echo "  3) 清理 /etc/fstab"
        echo "  0) 退出"
        echo "========================================"
        read -p "请选择 [0-3]: " -r choice

        case $choice in
            1) create_and_mount_partition ;;
            2) delete_partition ;;
            3) clean_fstab ;;
            0) log_info "退出脚本"; exit 0 ;;
            *) log_error "无效选项: $choice" ;;
        esac
        echo
        read -n 1 -s -r -p "按任意键返回主菜单..."
    done
}

check_root
main_menu
