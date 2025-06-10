#!/bin/bash

#================================================================
# LXD 镜像管理助手 v1.1 (LXD Image Management Helper)
#
# 一个集成了安装、备份和恢复功能的交互式Shell脚本。
# 要求：以 root 或 sudo 权限运行。
#================================================================

# --- 全局配置 ---

# 预设要备份的镜像别名列表 (如果选择 "预设列表备份")
PRESET_ALIASES=(
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
BACKUPS_ROOT_DIR="/root/lxc_image_backups"

# --- 颜色定义 ---
COLOR_GREEN='\033[0;32m'
COLOR_YELLOW='\033[0;33m'
COLOR_RED='\033[0;31m'
COLOR_BLUE='\033[0;34m'
COLOR_RESET='\033[0m'


# --- 辅助函数 ---

# 功能: 检查LXD是否已安装
function check_lxd_installed() {
    if command -v lxd &> /dev/null; then
        return 0 # 0 代表 true (已安装)
    else
        return 1 # 1 代表 false (未安装)
    fi
}

# --- 核心功能函数 ---

# 功能: 安装并初始化 LXD
function install_lxd() {
    echo -e "${COLOR_BLUE}--- 开始安装 LXD ---${COLOR_RESET}"

    if ! command -v apt &> /dev/null; then
        echo -e "${COLOR_RED}错误: 本脚本仅支持使用 'apt' 包管理器的系统 (如 Debian, Ubuntu)。${COLOR_RESET}"
        return 1
    fi

    if check_lxd_installed; then
        echo -e "${COLOR_GREEN}LXD 似乎已经安装。${COLOR_RESET}"
        lxd --version
        read -p "是否要强制运行 'lxd init --auto' 来重新进行自动化配置? (y/N): " re_init
        if [[ "$re_init" =~ ^[yY]([eE][sS])?$ ]]; then
            echo "正在运行 lxd init --auto..."
            lxd init --auto
        fi
        return 0
    fi
    
    echo "LXD 未安装。准备开始安装流程。"
    read -p "确认开始安装 LXD 吗? (y/N): " confirm
    if [[ ! "$confirm" =~ ^[yY]([eE][sS])?$ ]]; then
        echo "操作已取消。"
        return
    fi
    
    echo -e "${COLOR_YELLOW}步骤 1/3: 更新软件包列表...${COLOR_RESET}"
    apt update
    
    echo -e "${COLOR_YELLOW}步骤 2/3: 安装 LXD...${COLOR_RESET}"
    apt install -y lxd
    if [ $? -ne 0 ]; then
        echo -e "${COLOR_RED}LXD 安装失败。请检查错误信息。${COLOR_RESET}"
        return 1
    fi
    
    echo -e "${COLOR_YELLOW}步骤 3/3: 自动初始化 LXD...${COLOR_RESET}"
    lxd init --auto
    
    echo ""
    echo -e "${COLOR_GREEN}===============================================${COLOR_RESET}"
    echo -e "${COLOR_GREEN}LXD 安装并初始化完成！${COLOR_RESET}"
    lxd --version
    echo -e "${COLOR_GREEN}===============================================${COLOR_RESET}"
}


# 功能: 备份镜像
function backup_images() {
    if ! check_lxd_installed; then
        echo -e "${COLOR_RED}错误: LXD 命令未找到。请先从主菜单选择安装 LXD。${COLOR_RESET}"
        return 1
    fi

    echo -e "${COLOR_BLUE}--- 开始备份流程 ---${COLOR_RESET}"
    # ... (备份逻辑与上一版完全相同，此处省略以保持简洁) ...
    local backup_aliases=()
    echo "请选择要备份的镜像范围:"
    echo "  1) 备份所有本地镜像"
    echo "  2) 备份预设列表中的镜像"
    read -p "请输入选项 [1-2]: " choice
    case $choice in
        1)
            echo "正在获取所有本地镜像列表..."
            mapfile -t backup_aliases < <(lxc image list --format=csv -c a | tail -n +2)
            if [ ${#backup_aliases[@]} -eq 0 ]; then
                echo -e "${COLOR_RED}错误: 未找到任何本地LXD镜像。${COLOR_RESET}"
                return 1
            fi
            echo "将要备份所有 ${#backup_aliases[@]} 个本地镜像。"
            ;;
        2)
            backup_aliases=("${PRESET_ALIASES[@]}")
            echo "将要备份预设列表中的 ${#backup_aliases[@]} 个镜像。"
            ;;
        *)
            echo -e "${COLOR_RED}无效的选项。返回主菜单。${COLOR_RESET}"
            return 1
            ;;
    esac
    read -p "确认开始备份吗? (y/N): " confirm
    if [[ ! "$confirm" =~ ^[yY]([eE][sS])?$ ]]; then
        echo "操作已取消。"
        return
    fi
    local backup_dir="${BACKUPS_ROOT_DIR}_$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$backup_dir"
    echo -e "${COLOR_YELLOW}备份目录已创建: ${backup_dir}${COLOR_RESET}"
    echo "开始导出镜像..."
    for alias in "${backup_aliases[@]}"; do
        if ! lxc image info "$alias" >/dev/null 2>&1; then
            echo -e "  -> ${COLOR_RED}警告: 镜像 '$alias' 不存在, 已跳过。${COLOR_RESET}"
            continue
        fi
        echo -e "  -> 正在导出 ${COLOR_GREEN}$alias${COLOR_RESET} ..."
        lxc image export "$alias" "$backup_dir/$alias"
        if [ $? -ne 0 ]; then
            echo -e "  -> ${COLOR_RED}错误: 导出 '$alias' 失败。${COLOR_RESET}"
        fi
    done
    echo ""
    echo -e "${COLOR_GREEN}===============================================${COLOR_RESET}"
    echo -e "${COLOR_GREEN}所有选定镜像已成功备份至目录:${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}${backup_dir}${COLOR_RESET}"
    ls -lh "$backup_dir"
    echo -e "${COLOR_GREEN}===============================================${COLOR_RESET}"
}

# 功能: 恢复镜像
function restore_images() {
    if ! check_lxd_installed; then
        echo -e "${COLOR_RED}错误: LXD 命令未找到。请先从主菜单选择安装 LXD。${COLOR_RESET}"
        return 1
    fi

    echo -e "${COLOR_BLUE}--- 开始恢复流程 ---${COLOR_RESET}"
    # ... (恢复逻辑与上一版完全相同，此处省略以保持简洁) ...
    local backup_dirs=()
    mapfile -t backup_dirs < <(find "$(dirname "$BACKUPS_ROOT_DIR")" -maxdepth 1 -type d -name "$(basename "$BACKUPS_ROOT_DIR")_*" | sort -r)
    if [ ${#backup_dirs[@]} -eq 0 ]; then
        echo -e "${COLOR_RED}错误: 在 '${BACKUPS_ROOT_DIR%/*}' 目录下未找到任何备份目录 (例如: ${BACKUPS_ROOT_DIR}_*)。${COLOR_RESET}"
        echo "请确认备份目录存在, 或手动输入完整路径。"
        read -p "请输入备份目录的完整路径 (留空则返回): " manual_path
        if [ -z "$manual_path" ]; then
            return
        else
            restore_dir=$manual_path
        fi
    else
        echo "发现以下备份目录，请选择一个进行恢复:"
        local i=1
        for dir in "${backup_dirs[@]}"; do
            echo "  $i) $dir"
            ((i++))
        done
        read -p "请输入选项 [1-${#backup_dirs[@]}]: " choice
        if [[ "$choice" -ge 1 && "$choice" -le ${#backup_dirs[@]} ]]; then
            restore_dir=${backup_dirs[$((choice-1))]}
        else
            echo -e "${COLOR_RED}无效的选项。返回主菜单。${COLOR_RESET}"
            return
        fi
    fi
    echo -e "将从以下目录恢复: ${COLOR_YELLOW}$restore_dir${COLOR_RESET}"
    if [ ! -d "$restore_dir" ] || ! ls "$restore_dir"/*.tar.gz 1> /dev/null 2>&1; then
        echo -e "${COLOR_RED}错误: 目录 '$restore_dir' 不存在或目录内没有 .tar.gz 备份文件。${COLOR_RESET}"
        return 1
    fi
    for file in "$restore_dir"/*.tar.gz; do
        local alias
        alias=$(basename "$file" .tar.gz)
        echo -e "-------------------------------------------"
        echo -e "准备恢复镜像: ${COLOR_GREEN}$alias${COLOR_RESET}"
        if lxc image info "$alias" >/dev/null 2>&1; then
            read -p "$(echo -e "${COLOR_YELLOW}警告: 镜像 '$alias' 已存在。是否覆盖? (y/N): ${COLOR_RESET}")" overwrite
            if [[ "$overwrite" =~ ^[yY]([eE][sS])?$ ]]; then
                echo "  -> 正在删除旧镜像..."
                lxc image delete "$alias"
            else
                echo "  -> 已跳过恢复 '$alias'。"
                continue
            fi
        fi
        echo "  -> 正在导入 '$alias' 从文件: $file"
        lxc image import "$file" --alias "$alias"
        if [ $? -eq 0 ]; then
            echo -e "  -> ${COLOR_GREEN}成功导入 '$alias'。${COLOR_RESET}"
        else
            echo -e "  -> ${COLOR_RED}错误: 导入 '$alias' 失败。${COLOR_RESET}"
        fi
    done
    echo ""
    echo -e "${COLOR_GREEN}===============================================${COLOR_RESET}"
    echo -e "${COLOR_GREEN}镜像恢复流程已完成。${COLOR_RESET}"
    lxc image list
    echo -e "${COLOR_GREEN}===============================================${COLOR_RESET}"
}

# --- 主菜单循环 ---
function main_menu() {
    # 确保备份根目录存在
    mkdir -p "$(dirname "$BACKUPS_ROOT_DIR")"

    while true; do
        clear
        echo -e "${COLOR_BLUE}#############################################${COLOR_RESET}"
        echo -e "${COLOR_BLUE}#          LXD 镜像管理助手 v1.1          #${COLOR_RESET}"
        echo -e "${COLOR_BLUE}#############################################${COLOR_RESET}"
        echo "请选择要执行的操作:"
        echo -e "  1) ${COLOR_GREEN}备份 LXD 镜像${COLOR_RESET}"
        echo -e "  2) ${COLOR_YELLOW}恢复 LXD 镜像${COLOR_RESET}"
        echo -e "  3) 列出本地 LXD 镜像"
        echo -e "  4) ${COLOR_BLUE}安装并初始化 LXD${COLOR_RESET}"
        echo -e "  5) ${COLOR_RED}退出脚本${COLOR_RESET}"
        read -p "请输入选项 [1-5]: " main_choice

        case $main_choice in
            1)
                backup_images
                ;;
            2)
                restore_images
                ;;
            3)
                if ! check_lxd_installed; then
                     echo -e "${COLOR_RED}错误: LXD 命令未找到。请先从主菜单选择安装 LXD。${COLOR_RESET}"
                else
                    echo -e "${COLOR_BLUE}--- 当前本地LXD镜像列表 ---${COLOR_RESET}"
                    lxc image list
                fi
                ;;
            4)
                install_lxd
                ;;
            5)
                echo "脚本已退出。"
                exit 0
                ;;
            *)
                echo -e "${COLOR_RED}无效的选项 '$main_choice'，请重新输入。${COLOR_RESET}"
                ;;
        esac
        echo ""
        read -p "按 [Enter] 键返回主菜单..."
    done
}


# --- 脚本入口 ---

# 检查是否以root用户运行
if [ "$(id -u)" -ne 0 ]; then
   echo -e "${COLOR_RED}错误: 请使用 sudo 或 root 用户运行此脚本。${COLOR_RESET}"
   echo "用法: sudo bash $0"
   exit 1
fi

main_menu
