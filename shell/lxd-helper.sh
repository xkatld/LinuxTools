#!/bin/bash

#================================================================
# LXD 镜像管理助手 v2.0 (LXD Image Management Helper)
#
# 作者: xkatld & gemini
# 功能: 一个专业、健壮、用户友好的LXD镜像管理工具，集成了安装、
#       备份、恢复和查看功能。
# 用法: sudo bash lxd_helper.sh
#================================================================

# --- 可配置变量 ---
# 将所有可配置项集中于此，方便修改。

# 预设要备份的镜像别名列表 (用于 "预设列表备份" 功能)
# 在此数组中添加或删除您自己的镜像别名。
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
# 脚本会自动在此目录下创建带时间戳的子目录，如 /root/lxc_image_backups_20250611_103000
BACKUPS_ROOT_DIR="/root/lxc_image_backups"


# --- 脚本内部变量 (通常无需修改) ---

# 颜色定义
COLOR_GREEN='\033[0;32m'
COLOR_YELLOW='\033[0;33m'
COLOR_RED='\033[0;31m'
COLOR_BLUE='\033[0;34m'
COLOR_RESET='\033[0m'


# --- 辅助函数 ---

# 功能: 打印带有颜色的消息
# 用法: print_msg "GREEN" "这是一条成功消息"
function print_msg() {
    local color_name="$1"
    local message="$2"
    local color_var="COLOR_${color_name^^}"
    echo -e "${!color_var}${message}${COLOR_RESET}"
}

# 功能: 检查核心依赖命令是否存在
# 退出条件: 如果必需的命令缺失，则脚本终止。
function check_dependencies() {
    local dependencies=("find" "sort" "mkdir" "id")
    local missing_deps=()
    for cmd in "${dependencies[@]}"; do
        if ! command -v "$cmd" &> /dev/null; then
            missing_deps+=("$cmd")
        fi
    done

    if [ ${#missing_deps[@]} -gt 0 ]; then
        print_msg "RED" "错误: 脚本运行缺少以下核心命令: ${missing_deps[*]}"
        print_msg "RED" "请安装这些命令后再运行脚本。"
        exit 1
    fi
}

# 功能: 检查LXD是否已安装
function is_lxd_installed() {
    command -v lxd &> /dev/null
}


# --- 核心功能函数 ---

# 功能: 安装并初始化 LXD
function install_lxd() {
    print_msg "BLUE" "--- 开始安装与初始化 LXD ---"

    if ! command -v apt &> /dev/null; then
        print_msg "RED" "错误: 本安装脚本仅支持使用 'apt' 包管理器的系统 (如 Debian, Ubuntu)。"
        return 1
    fi

    if is_lxd_installed; then
        print_msg "GREEN" "LXD 已经安装。"
        lxd --version
        read -p "是否要强制运行 'lxd init --auto' 来重新进行自动化配置? (y/N): " re_init
        if [[ "$re_init" =~ ^[yY](es)?$ ]]; then
            print_msg "YELLOW" "正在重新运行 lxd init --auto..."
            if ! lxd init --auto; then
                print_msg "RED" "LXD 重新初始化失败。请检查上面的错误信息。"
                return 1
            fi
            print_msg "GREEN" "LXD 重新初始化成功。"
        fi
        return 0
    fi

    print_msg "YELLOW" "LXD 未安装。即将开始安装流程。"
    read -p "确认开始安装 LXD 吗? (y/N): " confirm
    if [[ ! "$confirm" =~ ^[yY](es)?$ ]]; then
        echo "操作已取消。"
        return
    fi

    print_msg "YELLOW" "步骤 1/3: 更新软件包列表..."
    apt update

    print_msg "YELLOW" "步骤 2/3: 安装 LXD..."
    if ! apt install -y lxd; then
        print_msg "RED" "LXD 安装失败。请检查错误信息。"
        return 1
    fi

    print_msg "YELLOW" "步骤 3/3: 自动初始化 LXD..."
    if ! lxd init --auto; then
        print_msg "RED" "LXD 初始化 (lxd init --auto) 失败。请检查错误信息。"
        return 1
    fi

    echo ""
    print_msg "GREEN" "==============================================="
    print_msg "GREEN" "LXD 安装并初始化完成！"
    lxd --version
    print_msg "GREEN" "==============================================="
}


# 功能: 备份镜像
function backup_images() {
    print_msg "BLUE" "--- 开始 LXD 镜像备份流程 ---"
    
    local backup_aliases=()
    echo "请选择要备份的镜像范围:"
    echo "  1) 备份所有本地镜像"
    echo "  2) 备份预设列表中的镜像"
    read -p "请输入选项 [1-2]: " choice

    case $choice in
        1)
            print_msg "YELLOW" "正在获取所有本地镜像列表..."
            # 使用 lxc image list --format=csv 获取纯净的别名列表，避免了复杂处理
            mapfile -t backup_aliases < <(lxc image list --format=csv -c a)
            if [ ${#backup_aliases[@]} -eq 0 ]; then
                print_msg "RED" "错误: 未找到任何本地 LXD 镜像。"
                return 1
            fi
            print_msg "YELLOW" "将要备份所有 ${#backup_aliases[@]} 个本地镜像。"
            ;;
        2)
            backup_aliases=("${PRESET_ALIASES[@]}")
            print_msg "YELLOW" "将要备份预设列表中的 ${#backup_aliases[@]} 个镜像。"
            ;;
        *)
            print_msg "RED" "无效的选项。返回主菜单。"
            return 1
            ;;
    esac

    read -p "确认开始备份吗? (y/N): " confirm
    if [[ ! "$confirm" =~ ^[yY](es)?$ ]]; then
        echo "操作已取消。"
        return
    fi

    local backup_dir="${BACKUPS_ROOT_DIR}_$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$backup_dir"
    print_msg "YELLOW" "备份目录已创建: ${backup_dir}"
    
    echo "开始导出镜像..."
    local success_count=0
    local fail_count=0
    for alias in "${backup_aliases[@]}"; do
        # 检查变量是否为空
        if [ -z "$alias" ]; then continue; fi

        if ! lxc image info "$alias" &>/dev/null; then
            print_msg "RED" "  -> 警告: 镜像 '$alias' 不存在, 已跳过。"
            ((fail_count++))
            continue
        fi
        
        print_msg "GREEN" "  -> 正在导出 $alias ..."
        if lxc image export "$alias" "$backup_dir/$alias"; then
            print_msg "GREEN" "     导出成功: $backup_dir/$alias.tar.gz"
            ((success_count++))
        else
            print_msg "RED" "  -> 错误: 导出 '$alias' 失败。"
            ((fail_count++))
        fi
    done

    echo ""
    print_msg "GREEN" "==============================================="
    print_msg "GREEN" "备份流程完成。"
    print_msg "GREEN" "成功: $success_count, 失败/跳过: $fail_count"
    print_msg "GREEN" "所有备份文件存放于:"
    print_msg "YELLOW" "$backup_dir"
    ls -lh "$backup_dir"
    print_msg "GREEN" "==============================================="
}


# 功能: 恢复镜像
function restore_images() {
    print_msg "BLUE" "--- 开始 LXD 镜像恢复流程 ---"

    # 更稳健地查找备份目录
    if ! [ -d "$(dirname "$BACKUPS_ROOT_DIR")" ]; then
         print_msg "RED" "错误: 备份根目录 '$(dirname "$BACKUPS_ROOT_DIR")' 不存在。"
         return 1
    fi
    
    local backup_dirs=()
    # 使用 find -print0 和 xargs -0 来安全处理可能包含特殊字符的路径
    mapfile -t backup_dirs < <(find "$(dirname "$BACKUPS_ROOT_DIR")" -maxdepth 1 -type d -name "$(basename "$BACKUPS_ROOT_DIR")_*" -print0 | xargs -0 ls -td)

    local restore_dir=""
    if [ ${#backup_dirs[@]} -eq 0 ]; then
        print_msg "YELLOW" "未自动找到任何备份目录 (例如: ${BACKUPS_ROOT_DIR}_*)。"
        read -p "请输入备份目录的完整路径 (留空则返回): " manual_path
        if [ -z "$manual_path" ]; then
            return
        else
            restore_dir="$manual_path"
        fi
    else
        echo "发现以下备份目录 (按时间倒序)，请选择一个进行恢复:"
        local i=1
        for dir in "${backup_dirs[@]}"; do
            echo "  $i) $dir"
            ((i++))
        done
        read -p "请输入选项 [1-${#backup_dirs[@]}]: " choice
        if [[ "$choice" -ge 1 && "$choice" -le ${#backup_dirs[@]} ]]; then
            restore_dir="${backup_dirs[$((choice-1))]}"
        else
            print_msg "RED" "无效的选项。返回主菜单。"
            return
        fi
    fi

    print_msg "YELLOW" "将从以下目录恢复: $restore_dir"
    if [ ! -d "$restore_dir" ] || ! ls -A "$restore_dir" | grep -q "."; then
        print_msg "RED" "错误: 目录 '$restore_dir' 不存在或为空。"
        return 1
    fi

    # 查找所有镜像文件 (tar.gz, .squashfs)
    local image_files=()
    mapfile -t image_files < <(find "$restore_dir" -maxdepth 1 -type f \( -name "*.tar.gz" -o -name "*.squashfs" \))

    if [ ${#image_files[@]} -eq 0 ]; then
        print_msg "RED" "错误: 在 '$restore_dir' 目录内没有找到任何镜像文件 (*.tar.gz, *.squashfs)。"
        return 1
    fi

    for file in "${image_files[@]}"; do
        # 提取别名，兼容 .tar.gz 和 unified.tar.gz 等
        local alias
        alias=$(basename "$file" | sed 's/\.tar\.gz$//;s/\.squashfs$//')
        
        print_msg "BLUE" "-------------------------------------------"
        print_msg "YELLOW" "准备恢复镜像: $alias"

        if lxc image info "$alias" &>/dev/null; then
            local prompt_msg
            prompt_msg=$(print_msg "YELLOW" "警告: 镜像 '$alias' 已存在。是否删除旧镜像并覆盖? (y/N): ")
            read -p "$prompt_msg" overwrite
            
            if [[ "$overwrite" =~ ^[yY](es)?$ ]]; then
                print_msg "RED" "  -> 危险操作: 正在删除旧镜像 '$alias'..."
                if ! lxc image delete "$alias"; then
                    print_msg "RED" "     删除失败！跳过此镜像的恢复。"
                    continue
                fi
                print_msg "GREEN" "     旧镜像已删除。"
            else
                echo "  -> 已跳过恢复 '$alias'。"
                continue
            fi
        fi

        echo "  -> 正在从文件导入: $file"
        if lxc image import "$file" --alias "$alias"; then
            print_msg "GREEN" "  -> 成功导入 '$alias'。"
        else
            print_msg "RED" "  -> 错误: 导入 '$alias' 失败。"
        fi
    done
    
    echo ""
    print_msg "GREEN" "==============================================="
    print_msg "GREEN" "镜像恢复流程已完成。"
    lxc image list
    print_msg "GREEN" "==============================================="
}


# 功能: 主菜单循环
function main_menu() {
    # 确保备份根目录的父目录存在
    mkdir -p "$(dirname "$BACKUPS_ROOT_DIR")"

    while true; do
        clear
        print_msg "BLUE" "#############################################"
        print_msg "BLUE" "#         LXD 镜像管理助手 v2.0         #"
        print_msg "BLUE" "#############################################"
        echo "请选择要执行的操作:"
        echo -e "  1) ${COLOR_BLUE}安装或检查 LXD 环境${COLOR_RESET}"
        echo -e "  2) ${COLOR_GREEN}备份 LXD 镜像${COLOR_RESET}"
        echo -e "  3) ${COLOR_YELLOW}恢复 LXD 镜像${COLOR_RESET}"
        echo -e "  4) 列出本地 LXD 镜像"
        echo -e "  5) ${COLOR_RED}退出脚本${COLOR_RESET}"
        read -p "请输入选项 [1-5]: " main_choice

        case $main_choice in
            1)
                install_lxd
                ;;
            2)
                backup_images
                ;;
            3)
                restore_images
                ;;
            4)
                print_msg "BLUE" "--- 当前本地LXD镜像列表 ---"
                lxc image list
                ;;
            5)
                echo "脚本已退出。"
                exit 0
                ;;
            *)
                print_msg "RED" "无效的选项 '$main_choice'，请重新输入。"
                ;;
        esac
        echo ""
        read -p "按 [Enter] 键返回主菜单..."
    done
}


# --- 脚本入口 ---

# 0. 检查脚本依赖
check_dependencies

# 1. 检查是否以root用户运行
if [ "$(id -u)" -ne 0 ]; then
   print_msg "RED" "错误: 请使用 sudo 或 root 用户运行此脚本。"
   echo "用法: sudo bash $0"
   exit 1
fi

# 2. 检查LXD是否已安装，并提供引导
if ! is_lxd_installed; then
    clear
    print_msg "YELLOW" "#####################################################"
    print_msg "YELLOW" "#                  欢迎使用LXD助手                  #"
    print_msg "YELLOW" "#####################################################"
    print_msg "RED" "\n检测到您的系统尚未安装 LXD。"
    print_msg "YELLOW" "您可以选择立即安装，或退出脚本。\n"
    
    select choice in "安装 LXD" "退出"; do
        case $choice in
            "安装 LXD")
                install_lxd
                # 安装后，如果LXD仍然不存在，则退出
                if ! is_lxd_installed; then
                    print_msg "RED" "安装过程似乎未成功，脚本即将退出。"
                    exit 1
                fi
                break
                ;;
            "退出")
                echo "脚本已退出。"
                exit 0
                ;;
        esac
    done
fi

# 3. 进入主菜单
main_menu
