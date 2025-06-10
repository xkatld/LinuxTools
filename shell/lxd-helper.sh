#!/bin/bash
#
# ====================================================================
# Script Name:    LXD 镜像管理助手 (LXD Image Management Helper) v2.2
# Author:         xkatld & gemini
# Description:    一个专业、健壮、用户友好的LXD镜像管理工具，集
#                 成了安装、备份、恢复和查看功能。
#                 v2.2: 修复了镜像列表解析的Bug，并引入'jq'以实现更可靠的输出处理。
# Usage:          sudo bash /path/to/lxd-helper.sh
# ====================================================================

# --- 脚本核心行为设定 ---
set -o errexit
set -o nounset
set -o pipefail

# --- 可配置变量 (Configurable Area) ---
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
readonly BACKUPS_ROOT_DIR="/root/lxc_image_backups"

# --- 样式与颜色定义 (Style and Color Definitions) ---
readonly COLOR_GREEN='\033[0;32m'
readonly COLOR_YELLOW='\033[1;33m'
readonly COLOR_RED='\033[0;31m'
readonly COLOR_BLUE='\033[0;34m'
readonly COLOR_NC='\033[0m' # No Color / Reset

# --- 辅助函数 (Utility Functions) ---

msg() {
    local color_name="$1"
    local message="$2"
    local color_var="COLOR_${color_name^^}"
    echo -e "${!color_var}${message}${COLOR_NC}"
}

check_dependencies() {
    msg "BLUE" "Step 1: 检查核心依赖..."
    # 新增了 jq 作为核心依赖，用于可靠地解析LXD的JSON输出
    local dependencies=("lxc" "find" "sort" "mkdir" "id" "jq")
    local missing_deps=()
    local apt_missing=()

    for cmd in "${dependencies[@]}"; do
        if ! command -v "$cmd" &> /dev/null; then
            if [[ "$cmd" == "lxc" ]]; then
                continue # LXD可以由脚本自己安装，跳过
            fi
            missing_deps+=("$cmd")
            # 如果是apt系，记录下来以便给出安装提示
            if command -v apt-get &> /dev/null; then
                 apt_missing+=("$cmd")
            fi
        fi
    done

    if [ ${#missing_deps[@]} -gt 0 ]; then
        msg "RED" "错误: 脚本运行缺少以下核心命令: ${missing_deps[*]}"
        if [ ${#apt_missing[@]} -gt 0 ]; then
            msg "YELLOW" "在 Debian/Ubuntu 系统上，您可以通过以下命令安装它们:"
            msg "YELLOW" "sudo apt-get update && sudo apt-get install -y ${apt_missing[*]}"
        fi
        exit 1
    fi
    msg "GREEN" "核心依赖检查通过。"
}

is_lxd_installed() {
    command -v lxd &> /dev/null
}

# --- 核心功能函数 (Core Functions) ---

install_lxd() {
    msg "BLUE" "--- LXD 环境安装与配置 ---"
    # ... 此函数无变化 ...
    if ! command -v apt &> /dev/null; then
        msg "RED" "错误: 本安装脚本仅支持使用 'apt' 的系统 (如 Debian, Ubuntu)。"
        return 1
    fi
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

backup_images() {
    msg "BLUE" "--- LXD 镜像备份 ---"
    
    local backup_aliases=()
    echo "请选择要备份的镜像范围:"
    echo "  1) 备份所有本地镜像 (仅限有别名的)"
    echo "  2) 备份预设列表中的镜像 (${#PRESET_ALIASES[@]} 个)"
    read -p "请输入选项 [1-2]: " choice

    case "$choice" in
        1)
            msg "YELLOW" "正在获取所有带别名的本地镜像列表 (需要 'jq')..."
            # 【关键修复】使用 jq 解析 JSON 输出，确保只获取真实存在的别名
            # 这可以从根本上避免解析纯文本可能带来的各种问题（如您遇到的错误）
            if ! mapfile -t backup_aliases < <(lxc image list --format=json | jq -r '.[].aliases[].name'); then
                msg "RED" "错误: 使用 'lxc' 和 'jq' 获取镜像列表失败。"
                msg "RED" "请确保 LXD 运行正常且 'jq' 已安装。"
                return 1
            fi
            
            if [ ${#backup_aliases[@]} -eq 0 ]; then
                msg "RED" "错误: 未找到任何带有别名(alias)的本地 LXD 镜像可供备份。"
                return 1
            fi
            msg "YELLOW" "将要备份所有 ${#backup_aliases[@]} 个带别名的本地镜像。"
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
        # 即使列表很干净，也保留此检查作为“深度防御”，以防万一
        if ! lxc image info "$alias" &>/dev/null; then
            msg "RED" "  -> 警告: 预设的镜像 '$alias' 在本地不存在, 已跳过。"
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

restore_images() {
    msg "BLUE" "--- LXD 镜像恢复 ---"
    # ... 此函数无变化 ...
    if ! [ -d "$(dirname "${BACKUPS_ROOT_DIR}")" ]; then
         msg "RED" "错误: 备份根目录 '$(dirname "${BACKUPS_ROOT_DIR}")' 不存在。"
         return 1
    fi
    local backup_dirs=()
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

main_menu() {
    # ... 此函数无变化 ...
    mkdir -p "$(dirname "${BACKUPS_ROOT_DIR}")"
    while true; do
        clear
        msg "BLUE" "#############################################"
        msg "BLUE" "#         LXD 镜像管理助手 v2.2         #"
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

# 0. 权限检查
if [ "$(id -u)" -ne 0 ]; then
   msg "RED" "错误: 此脚本必须以 root 权限运行。请使用 'sudo bash $0'"
   exit 1
fi

# 1. 环境检查
check_dependencies

# 2. 引导逻辑
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
