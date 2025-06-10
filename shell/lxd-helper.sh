#!/bin/bash

set -o errexit
set -o nounset
set -o pipefail

readonly BACKUPS_ROOT_DIR="/root/lxc_image_backups"

readonly COLOR_GREEN='\033[0;32m'
readonly COLOR_YELLOW='\033[1;33m'
readonly COLOR_RED='\033[0;31m'
readonly COLOR_BLUE='\033[0;34m'
readonly COLOR_NC='\033[0m'

msg() {
    local color_name="$1"
    local message="$2"
    local color_var="COLOR_${color_name^^}"
    echo -e "${!color_var}${message}${COLOR_NC}"
}

check_root() {
    if [[ "$(id -u)" -ne 0 ]]; then
        msg "RED" "错误: 此脚本必须以 root 权限运行。请使用 'sudo bash $0'"
        exit 1
    fi
}

check_dependencies() {
    msg "BLUE" "正在检查核心依赖..."
    local dependencies=("lxc" "jq" "snap")
    local missing_deps=()
    for cmd in "${dependencies[@]}"; do
        if ! command -v "$cmd" &>/dev/null; then
            if [[ "$cmd" == "lxc" && -f "/snap/bin/lxc" ]]; then
                continue
            fi
            missing_deps+=("$cmd")
        fi
    done
    if [ ${#missing_deps[@]} -gt 0 ]; then
        msg "RED" "错误: 脚本运行缺少以下核心命令: ${missing_deps[*]}"
        if command -v apt-get &>/dev/null; then
            msg "YELLOW" "在 Debian/Ubuntu 系统上，您可以通过以下命令安装它们:"
            msg "YELLOW" "sudo apt-get update && sudo apt-get install -y ${missing_deps[*]}"
        fi
        exit 1
    fi
    msg "GREEN" "核心依赖检查通过。"
}

is_lxd_installed() {
    if command -v lxd &>/dev/null || [[ -f "/snap/bin/lxd" ]]; then
        return 0
    else
        return 1
    fi
}

install_lxd() {
    msg "BLUE" "--- LXD 环境安装与配置 ---"
    if is_lxd_installed; then
        msg "GREEN" "LXD 已经安装。"
        lxd --version
        read -p "$(msg "YELLOW" "是否要强制重新进行自动化配置 (lxd init --auto)? [y/N]: ")" re_init
        if [[ "${re_init}" =~ ^[yY]$ ]]; then
            msg "YELLOW" "正在重新运行 lxd init --auto..."
            if sudo lxd init --auto; then
                msg "GREEN" "LXD 重新初始化成功。"
            else
                msg "RED" "LXD 重新初始化失败，请检查上面的错误信息。"
                return 1
            fi
        fi
        return 0
    fi

    if ! command -v apt-get &>/dev/null; then
        msg "RED" "错误: 本安装脚本目前主要为基于 'apt' 的系统 (如 Debian, Ubuntu) 提供自动安装支持。"
        return 1
    fi

    msg "YELLOW" "检测到 LXD 未安装，即将开始安装流程。"
    read -p "$(msg "YELLOW" "确认开始安装 LXD 吗? [y/N]: ")" confirm
    if [[ ! "${confirm}" =~ ^[yY]$ ]]; then
        msg "BLUE" "操作已由用户取消。"
        return
    fi

    msg "BLUE" "步骤 1/3: 更新软件包列表..."
    sudo apt-get update -y
    msg "BLUE" "步骤 2/3: 安装 snapd..."
    sudo apt-get install -y snapd
    msg "BLUE" "步骤 3/3: 通过 Snap 安装并初始化 LXD..."
    if ! sudo snap install lxd; then
        msg "RED" "通过 Snap 安装 LXD 失败，请检查错误信息。"
        return 1
    fi

    if ! sudo lxd init --auto; then
        msg "RED" "LXD 初始化 (lxd init --auto) 失败，请检查错误信息。"
        return 1
    fi
    echo ""
    msg "GREEN" "==============================================="
    msg "GREEN" "✓ LXD 安装并初始化完成！"
    sudo lxd --version
    msg "GREEN" "==============================================="
}

backup_images() {
    msg "BLUE" "--- LXD 镜像备份 ---"
    
    msg "YELLOW" "正在获取所有本地镜像列表..."
    local image_aliases
    if ! image_aliases=$(lxc image list --format=json | jq -r '.[] | select(.aliases | length > 0) | .aliases[0].name'); then
        msg "RED" "错误: 使用 'lxc' 和 'jq' 获取镜像列表失败。"
        return 1
    fi

    if [[ -z "$image_aliases" ]]; then
        msg "RED" "错误: 未找到任何带有别名(alias)的本地 LXD 镜像可供备份。"
        return 1
    fi
    
    mapfile -t backup_aliases < <(echo "$image_aliases")
    msg "YELLOW" "检测到 ${#backup_aliases[@]} 个带别名的本地镜像，将逐一备份。"

    read -p "$(msg "YELLOW" "确认开始备份吗? [y/N]: ")" confirm
    if [[ ! "${confirm}" =~ ^[yY]$ ]]; then
        msg "BLUE" "操作已由用户取消。"
        return
    fi

    local backup_dir="${BACKUPS_ROOT_DIR}_$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$backup_dir"
    msg "YELLOW" "所有备份文件将存放在: ${backup_dir}"
    
    echo ""
    msg "BLUE" "开始导出镜像..."
    local success_count=0
    local fail_count=0

    for alias in "${backup_aliases[@]}"; do
        msg "GREEN" "  -> 正在导出 $alias ..."
        if lxc image export "$alias" "$backup_dir/$alias"; then
            msg "GREEN" "     ✓ 导出成功: $backup_dir/$alias.tar.gz"
            ((success_count++))
        else
            msg "RED" "     ✗ 错误: 导出 '$alias' 失败。"
            ((fail_count++))
        fi
    done

    echo ""
    msg "GREEN" "==============================================="
    msg "GREEN" "备份流程完成。"
    msg "GREEN" "成功: $success_count, 失败/跳过: $fail_count"
    msg "YELLOW" "备份文件列表:"
    ls -lh "$backup_dir"
    msg "GREEN" "==============================================="
}

restore_images() {
    msg "BLUE" "--- LXD 镜像恢复 ---"
    if ! [ -d "$(dirname "${BACKUPS_ROOT_DIR}")" ]; then
         msg "RED" "错误: 备份根目录 '$(dirname "${BACKUPS_ROOT_DIR}")' 不存在。"
         return 1
    fi

    local backup_dirs=()
    if ! mapfile -t backup_dirs < <(find "$(dirname "${BACKUPS_ROOT_DIR}")" -maxdepth 1 -type d -name "$(basename "${BACKUPS_ROOT_DIR}")_*" -print0 | xargs -0 ls -td); then
        msg "YELLOW" "未能通过 'mapfile' 读取备份目录。"
    fi

    if [ ${#backup_dirs[@]} -eq 0 ]; then
        msg "RED" "错误: 未找到任何有效的备份目录 (如: ${BACKUPS_ROOT_DIR}_*)。"
        return 1
    fi
    
    echo "发现以下备份目录 (按时间倒序)，请选择一个进行恢复:"
    local i=1
    for dir in "${backup_dirs[@]}"; do
        echo "  $i) $dir"
        ((i++))
    done

    read -p "请输入选项 [1-${#backup_dirs[@]}] (或按Enter取消): " choice
    if [[ ! "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 )) || (( choice > ${#backup_dirs[@]} )); then
         msg "BLUE" "无效选择或用户取消，操作终止。"
         return
    fi
    
    local restore_dir="${backup_dirs[$((choice-1))]}"
    msg "YELLOW" "将从以下目录恢复: $restore_dir"

    if [ ! -d "$restore_dir" ] || [ -z "$(ls -A "$restore_dir")" ]; then
        msg "RED" "错误: 目录 '$restore_dir' 不存在或为空。"
        return 1
    fi

    local image_files=()
    mapfile -t image_files < <(find "$restore_dir" -maxdepth 1 -type f \( -name "*.tar.gz" -o -name "*.squashfs" \))
    if [ ${#image_files[@]} -eq 0 ]; then
        msg "RED" "错误: 在 '$restore_dir' 目录内没有找到任何镜像文件 (*.tar.gz, *.squashfs)。"
        return 1
    fi

    for file in "${image_files[@]}"; do
        local alias
        alias=$(basename "$file" .tar.gz)
        msg "BLUE" "-------------------------------------------"
        msg "YELLOW" "准备恢复镜像: $alias"

        if lxc image info "$alias" &>/dev/null; then
            read -p "$(msg "YELLOW" "镜像 '$alias' 已存在。是否删除旧镜像并覆盖? [y/N]: ")" overwrite
            if [[ "${overwrite}" =~ ^[yY]$ ]]; then
                msg "RED" "  -> 正在删除旧镜像 '$alias'..."
                if lxc image delete "$alias"; then
                    msg "GREEN" "     ✓ 旧镜像已删除。"
                else
                    msg "RED" "     删除失败！跳过此镜像的恢复。"
                    continue
                fi
            else
                msg "BLUE" "  -> 已跳过恢复 '$alias'。"
                continue
            fi
        fi

        msg "GREEN" "  -> 正在从文件导入: $file"
        if lxc image import "$file" --alias "$alias"; then
            msg "GREEN" "  -> ✓ 成功导入 '$alias'。"
        else
            msg "RED" "  -> ✗ 错误: 导入 '$alias' 失败。"
        fi
    done

    echo ""
    msg "GREEN" "==============================================="
    msg "GREEN" "镜像恢复流程已完成。"
    lxc image list
    msg "GREEN" "==============================================="
}

main_menu() {
    while true; do
        clear
        msg "BLUE" "#############################################"
        msg "BLUE" "#         LXD 镜像管理助手 (重构版)         #"
        msg "BLUE" "#############################################"
        echo "请选择要执行的操作:"
        echo -e "  1) ${COLOR_BLUE}安装或检查 LXD 环境${COLOR_NC}"
        echo -e "  2) ${COLOR_GREEN}备份所有 LXD 镜像${COLOR_NC}"
        echo -e "  3) ${COLOR_YELLOW}从备份恢复 LXD 镜像${COLOR_NC}"
        echo -e "  4) 列出本地 LXD 镜像"
        echo -e "  5) ${COLOR_RED}退出脚本${COLOR_NC}"
        read -p "请输入选项 [1-5]: " main_choice

        case $main_choice in
            1) install_lxd ;;
            2) backup_images ;;
            3) restore_images ;;
            4)
                msg "BLUE" "--- 当前本地LXD镜像列表 ---"
                lxc image list
                ;;
            5)
                msg "BLUE" "脚本已退出。"
                exit 0
                ;;
            *)
                msg "RED" "无效的选项 '$main_choice'，请重新输入。"
                ;;
        esac
        echo ""
        read -n 1 -s -r -p "按任意键返回主菜单..."
    done
}

check_root
if ! is_lxd_installed; then
    clear
    msg "RED" "检测到您的系统尚未安装 LXD。"
    read -p "$(msg "YELLOW" "是否立即安装LXD? (需要apt包管理器) [y/N]: ")" install_now
    if [[ "${install_now}" =~ ^[yY]$ ]]; then
        install_lxd
        if ! is_lxd_installed; then
             msg "RED" "安装过程似乎未成功，脚本即将退出。"
             exit 1
        fi
    else
        msg "BLUE" "用户选择不安装，脚本退出。"
        exit 0
    fi
fi

check_dependencies
main_menu
