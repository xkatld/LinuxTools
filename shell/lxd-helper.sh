#!/bin/bash
#
# ====================================================================
# Script Name:    LXD 镜像管理助手 (LXD Image Management Helper) v2.1
# Author:         xkatld & gemini
# Description:    一个专业、健壮、用户友好的LXD镜像管理工具，集
#                 成了安装、备份、恢复和查看功能。
# Usage:          sudo bash /path/to/lxd-helper.sh
# ====================================================================

# --- 脚本核心行为设定 ---
# 这三个命令让脚本变得更安全、更可预测：
# -e: 任何命令执行失败，脚本立即退出。
# -u: 尝试使用未定义的变量，脚本会报错并退出。
# -o pipefail: 管道中的任何一个命令失败，整个管道都算失败。
set -o errexit
set -o nounset
set -o pipefail

# --- 可配置变量 (Configurable Area) ---
# 将所有可配置项集中于此，方便修改。

# 预设要备份的镜像别名列表 (用于 "预设列表备份" 功能)
# 在此数组中添加或删除您自己的镜像别名。
readonly PRESET_ALIASES=(
    "almalinux8-amd64-ssh"
    "almalinux9-amd64-ssh"
    "centos9-stream-amd64-ssh"
    "debian11-amd64-ssh"
    "debian12-amd64-ssh"
    "ubuntu22-04-amd64-ssh"
    "ubuntu24-04-amd64-ssh"
    "rockylinux9-amd64-ssh"
)

# 备份文件存放的根目录
# 脚本会自动在此目录下创建带时间戳的子目录。
readonly BACKUPS_ROOT_DIR="/root/lxc_image_backups"


# --- 样式与颜色定义 (Style and Color Definitions) ---
readonly COLOR_GREEN='\033[0;32m'
readonly COLOR_YELLOW='\033[1;33m'
readonly COLOR_RED='\033[0;31m'
readonly COLOR_BLUE='\033[0;34m'
readonly COLOR_NC='\033[0m' # No Color / Reset


# --- 辅助函数 (Utility Functions) ---

# 功能: 打印带有颜色的消息，使输出更具可读性。
# 用法: msg "GREEN" "这是一条成功消息"
msg() {
    local color_name="$1"
    local message="$2"
    local color_var="COLOR_${color_name^^}"
    echo -e "${!color_var}${message}${COLOR_NC}"
}

# 功能: 检查脚本运行所必需的外部命令。
check_dependencies() {
    msg "BLUE" "Step 1: 检查核心依赖..."
    local dependencies=("lxc" "find" "sort" "mkdir" "id")
    local missing_deps=()

    for cmd in "${dependencies[@]}"; do
        if ! command -v "$cmd" &> /dev/null; then
            # 'lxc' 命令特殊处理，因为脚本可以安装它
            if [[ "$cmd" == "lxc" ]]; then
                continue
            fi
            missing_deps+=("$cmd")
        fi
    done

    if [ ${#missing_deps[@]} -gt 0 ]; then
        msg "RED" "错误: 脚本运行缺少以下核心命令: ${missing_deps[*]}"
        msg "RED" "请先安装它们，然后再运行脚本。"
        exit 1
    fi
    msg "GREEN" "核心依赖检查通过。"
}

# 功能: 检查LXD是否已安装。
is_lxd_installed() {
    command -v lxd &> /dev/null
}


# --- 核心功能函数 (Core Functions) ---

# 功能: 安装并初始化 LXD。
install_lxd() {
    msg "BLUE" "--- LXD 环境安装与配置 ---"

    if ! command -v apt &> /dev/null; then
        msg "RED" "错误: 本安装脚本仅支持使用 'apt' 的系统 (如 Debian, Ubuntu)。"
        return 1
    fi

    # 如果已安装，提供重新初始化的选项
    if is_lxd_installed; then
        msg "GREEN" "LXD 已经安装。"
        lxd --version
        read -p "$(msg "YELLOW" "是否要强制重新进行自动化配置 (lxd init --auto)? [y/N]: ")" re_init
        if [[ "${re_init}" =~ ^[yY]$ ]]; then
            msg "YELLOW" "正在重新运行 lxd init --auto..."
            if ! lxd init --auto; then
                msg "RED" "LXD 重新初始化失败，请检查上面的错误信息。"
                return 1
            fi
            msg "GREEN" "LXD 重新初始化成功。"
        fi
        return 0
    fi

    # 如果未安装，则执行安装流程
    msg "YELLOW" "检测到 LXD 未安装，即将开始安装流程。"
    read -p "$(msg "YELLOW" "确认开始安装 LXD 吗? [y/N]: ")" confirm
    if [[ ! "${confirm}" =~ ^[yY]$ ]]; then
        msg "BLUE" "操作已由用户取消。"
        return
    fi

    msg "BLUE" "步骤 1/3: 更新软件包列表..."
    apt-get update -y
    msg "BLUE" "步骤 2/3: 安装 snapd..."
    apt-get install -y snapd
    msg "BLUE" "步骤 3/3: 通过 Snap 安装并初始化 LXD..."
    if ! snap install lxd; then
        msg "RED" "通过 Snap 安装 LXD 失败，请检查错误信息。"
        return 1
    fi

    if ! lxd init --auto; then
        msg "RED" "LXD 初始化 (lxd init --auto) 失败，请检查错误信息。"
        return 1
    fi

    echo ""
    msg "GREEN" "==============================================="
    msg "GREEN" " ✓ LXD 安装并初始化完成！"
    lxd --version
    msg "GREEN" "==============================================="
}

# 功能: 备份LXD镜像。
backup_images() {
    msg "BLUE" "--- LXD 镜像备份 ---"
    
    local backup_aliases=()
    echo "请选择要备份的镜像范围:"
    echo "  1) 备份所有本地镜像"
    echo "  2) 备份预设列表中的镜像 (${#PRESET_ALIASES[@]} 个)"
    read -p "请输入选项 [1-2]: " choice

    case "$choice" in
        1)
            msg "YELLOW" "正在获取所有本地镜像列表..."
            mapfile -t backup_aliases < <(lxc image list --format=csv -c a)
            if [ ${#backup_aliases[@]} -eq 0 ]; then
                msg "RED" "错误: 未找到任何本地 LXD 镜像可供备份。"
                return 1
            fi
            msg "YELLOW" "将要备份所有 ${#backup_aliases[@]} 个本地镜像。"
            ;;
        2)
            backup_aliases=("${PRESET_ALIASES[@]}")
            msg "YELLOW" "将要备份预设列表中的 ${#backup_aliases[@]} 个镜像。"
            ;;
        *)
            msg "RED" "无效的选项，操作取消。"
            return 1
            ;;
    esac

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
        if [[ -z "$alias" ]]; then continue; fi

        if ! lxc image info "$alias" &>/dev/null; then
            msg "RED" "  -> 警告: 镜像 '$alias' 不存在, 已跳过。"
            ((fail_count++))
            continue
        fi
        
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
    msg "GREEN" "备份文件列表:"
    ls -lh "$backup_dir"
    msg "GREEN" "==============================================="
}

# 功能: 从备份文件恢复LXD镜像。
restore_images() {
    msg "BLUE" "--- LXD 镜像恢复 ---"

    if ! [ -d "$(dirname "${BACKUPS_ROOT_DIR}")" ]; then
         msg "RED" "错误: 备份根目录 '$(dirname "${BACKUPS_ROOT_DIR}")' 不存在。"
         return 1
    fi
    
    local backup_dirs=()
    # 使用 find -print0 和 xargs -0 来安全处理可能包含特殊字符的路径，这是最健壮的方式
    mapfile -t backup_dirs < <(find "$(dirname "${BACKUPS_ROOT_DIR}")" -maxdepth 1 -type d -name "$(basename "${BACKUPS_ROOT_DIR}")_*" -print0 | xargs -0 ls -td)

    local restore_dir=""
    if [ ${#backup_dirs[@]} -eq 0 ]; then
        msg "YELLOW" "未自动找到任何备份目录 (如: ${BACKUPS_ROOT_DIR}_*)。"
        read -e -p "请输入备份目录的完整路径 (留空则返回): " manual_path
        if [[ -z "$manual_path" ]]; then
            return
        fi
        restore_dir="$manual_path"
    else
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
        restore_dir="${backup_dirs[$((choice-1))]}"
    fi

    msg "YELLOW" "将从以下目录恢复: $restore_dir"
    if [ ! -d "$restore_dir" ] || ! ls -A "$restore_dir" | grep -q "."; then
        msg "RED" "错误: 目录 '$restore_dir' 不存在或为空。"
        return 1
    fi

    # 查找所有镜像文件 (tar.gz, .squashfs)
    local image_files=()
    mapfile -t image_files < <(find "$restore_dir" -maxdepth 1 -type f \( -name "*.tar.gz" -o -name "*.squashfs" \))

    if [ ${#image_files[@]} -eq 0 ]; then
        msg "RED" "错误: 在 '$restore_dir' 目录内没有找到任何镜像文件 (*.tar.gz, *.squashfs)。"
        return 1
    fi

    for file in "${image_files[@]}"; do
        local alias
        alias=$(basename "$file" | sed 's/\.tar\.gz$//;s/\.squashfs$//')
        
        msg "BLUE" "-------------------------------------------"
        msg "YELLOW" "准备恢复镜像: $alias"

        if lxc image info "$alias" &>/dev/null; then
            msg "RED" "警告：此操作是不可逆的！"
            read -p "$(msg "YELLOW" "镜像 '$alias' 已存在。是否删除旧镜像并覆盖? [y/N]: ")" overwrite
            
            if [[ "${overwrite}" =~ ^[yY]$ ]]; then
                msg "RED" "  -> 危险操作: 正在删除旧镜像 '$alias'..."
                if ! lxc image delete "$alias"; then
                    msg "RED" "     删除失败！跳过此镜像的恢复。"
                    continue
                fi
                msg "GREEN" "     ✓ 旧镜像已删除。"
            else
                msg "BLUE" "  -> 已跳过恢复 '$alias'。"
                continue
            fi
        fi

        echo "  -> 正在从文件导入: $file"
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

# 功能: 显示主菜单并处理用户选择。
main_menu() {
    # 确保备份根目录的父目录存在
    mkdir -p "$(dirname "${BACKUPS_ROOT_DIR}")"

    while true; do
        clear
        msg "BLUE" "#############################################"
        msg "BLUE" "#         LXD 镜像管理助手 v2.1         #"
        msg "BLUE" "#############################################"
        echo "请选择要执行的操作:"
        echo -e "  1) ${COLOR_BLUE}安装或检查 LXD 环境${COLOR_NC}"
        echo -e "  2) ${COLOR_GREEN}备份 LXD 镜像${COLOR_NC}"
        echo -e "  3) ${COLOR_YELLOW}恢复 LXD 镜像${COLOR_NC}"
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


# --- 脚本入口 (Script Entrypoint) ---

# 0. 权限检查：必须以root身份运行
if [ "$(id -u)" -ne 0 ]; then
   msg "RED" "错误: 此脚本必须以 root 权限运行。请使用 'sudo bash $0'"
   exit 1
fi

# 1. 环境检查：检查核心依赖
check_dependencies

# 2. 引导逻辑：如果LXD未安装，引导用户安装
if ! is_lxd_installed; then
    clear
    msg "YELLOW" "#####################################################"
    msg "YELLOW" "#                  欢迎使用LXD助手                  #"
    msg "YELLOW" "#####################################################"
    msg "RED" "\n检测到您的系统尚未安装 LXD。"
    msg "YELLOW" "您可以选择立即安装，或退出脚本。\n"
    
    select choice in "安装 LXD" "退出脚本"; do
        case $choice in
            "安装 LXD")
                install_lxd
                # 安装后，如果LXD仍然不存在，则退出
                if ! is_lxd_installed; then
                    msg "RED" "安装过程似乎未成功，脚本即将退出。"
                    exit 1
                fi
                break
                ;;
            "退出脚本")
                msg "BLUE" "脚本已退出。"
                exit 0
                ;;
        esac
    done
fi

# 3. 启动主菜单
main_menu
