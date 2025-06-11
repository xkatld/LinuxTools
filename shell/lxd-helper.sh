#!/bin/bash

set -o errexit
set -o nounset
set -o pipefail

readonly BACKUPS_ROOT_DIR="/root/lxc_image_backups/lxc_image_backups"

readonly COLOR_GREEN='\033[0;32m'
readonly COLOR_YELLOW='\033[1;33m'
readonly COLOR_RED='\033[0;31m'
readonly COLOR_BLUE='\033[0;34m'
readonly COLOR_CYAN='\033[0;36m'
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
    local dependencies=("lxc" "jq" "wc" "lsblk" "curl" "truncate")
    local missing_deps=()
    for cmd in "${dependencies[@]}"; do
        if ! command -v "$cmd" &>/dev/null; then
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

set_lxd_pool_as_default() {
    local pool_name="$1"
    msg "BLUE" "\n将新存储池设置为默认配置..."
    read -p "$(msg "YELLOW" "是否要将 '$pool_name' 设置为默认 profile 的根磁盘池? (这会替换现有设置) [y/N]: ")" set_default
    if [[ "${set_default}" =~ ^[yY]$ ]]; then
        msg "YELLOW" "正在修改默认 profile..."
        if lxc profile device remove default root && lxc profile device add default root disk path=/ pool="$pool_name"; then
            msg "GREEN" "✓ 默认 profile 已更新。"
            lxc profile show default
        else
            msg "RED" "修改默认 profile 失败。"
        fi
    else
        msg "BLUE" "已跳过修改默认 profile。"
    fi
}

is_lxd_installed() {
    command -v lxd &>/dev/null
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
        msg "RED" "错误: 本安装脚本仅支持使用 'apt' 的系统 (如 Debian, Ubuntu)。"
        return 1
    fi

    msg "YELLOW" "检测到 LXD 未安装，即将开始 APT 安装流程。"
    read -p "$(msg "YELLOW" "确认开始安装 LXD 吗? [y/N]: ")" confirm
    if [[ ! "${confirm}" =~ ^[yY]$ ]]; then
        msg "BLUE" "操作已由用户取消。"
        return
    fi

    msg "BLUE" "步骤 1/2: 更新软件包列表..."
    sudo apt-get update -y
    
    msg "BLUE" "步骤 2/2: 通过 APT 安装并初始化 LXD..."
    if ! sudo apt-get install -y lxd; then
        msg "RED" "通过 APT 安装 LXD 失败，请检查错误信息。"
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
    local image_aliases_list
    image_aliases_list=$(lxc image list --format=json | jq -r '.[] | select(.aliases | length > 0) | .aliases[0].name')

    if [[ -z "$image_aliases_list" ]]; then
        msg "RED" "错误: 未找到任何带有别名(alias)的本地 LXD 镜像可供备份。"
        return 1
    fi
    
    local image_count
    image_count=$(echo "$image_aliases_list" | wc -l)

    msg "YELLOW" "检测到 ${image_count} 个带别名的本地镜像，将逐一备份。"
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

    set +o errexit
    trap '' SIGHUP SIGINT SIGTERM

    while read -r alias; do
        if [[ -z "$alias" ]]; then
            continue
        fi
        msg "GREEN" "  -> 正在导出 $alias ..."
        
        command lxc image export "$alias" "$backup_dir/$alias" >/dev/null 2>&1
        local export_status=$?

        if [[ $export_status -eq 0 ]]; then
            msg "GREEN" "     ✓ 导出成功: $backup_dir/$alias.tar.gz"
            ((success_count++))
        else
            msg "RED" "     ✗ 错误: 导出 '$alias' 失败 (退出码: $export_status)。"
            ((fail_count++))
        fi
    done < <(echo "$image_aliases_list")
    
    trap - SIGHUP SIGINT SIGTERM
    set -o errexit

    echo ""
    msg "GREEN" "==============================================="
    msg "GREEN" "备份流程完成。"
    msg "GREEN" "成功: $success_count, 失败/跳过: $fail_count"
    
    if [[ $success_count -gt 0 ]]; then
        msg "YELLOW" "备份文件列表:"
        ls -lh "$backup_dir"
    fi
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

install_zfs_on_arm() {
    local zfs_build_script_url="https://raw.githubusercontent.com/xkatld/debian12-arm64-zfs/refs/heads/main/build_zfs_on_debian.sh"
    msg "YELLOW" "检测到 ARM 架构。将使用特定脚本编译安装 ZFS。"
    msg "YELLOW" "这可能需要较长时间，请耐心等待。"
    read -p "$(msg "YELLOW" "确认从 ${zfs_build_script_url} 下载并执行脚本吗? [y/N]: ")" confirm
    if [[ ! "${confirm}" =~ ^[yY]$ ]]; then
        msg "BLUE" "操作已由用户取消。"
        return 1
    fi
    
    local temp_script
    temp_script=$(mktemp)
    trap "rm -f '$temp_script'" EXIT HUP INT QUIT TERM

    msg "BLUE" "正在下载 ZFS 构建脚本..."
    if ! curl -fsSL "$zfs_build_script_url" -o "$temp_script"; then
        msg "RED" "下载脚本失败。"
        return 1
    fi
    
    chmod +x "$temp_script"
    msg "BLUE" "开始执行 ZFS 构建脚本..."
    if ! bash "$temp_script"; then
        msg "RED" "ZFS 构建和安装失败。请检查脚本输出。"
        return 1
    fi

    msg "GREEN" "✓ ZFS 编译安装完成。"
    rm -f "$temp_script"
    trap - EXIT HUP INT QUIT TERM
    return 0
}

install_zfs_standard() {
    msg "YELLOW" "即将通过 APT 安装 zfsutils-linux..."
    read -p "$(msg "YELLOW" "确认安装吗? [y/N]: ")" confirm
    if [[ ! "${confirm}" =~ ^[yY]$ ]]; then
        msg "BLUE" "操作已由用户取消。"
        return 1
    fi

    if ! sudo apt-get install -y zfsutils-linux; then
        msg "RED" "通过 APT 安装 zfsutils-linux 失败。"
        return 1
    fi
    
    msg "GREEN" "✓ zfsutils-linux 安装成功。"
    return 0
}

install_zfs() {
    msg "BLUE" "--- 检查并安装 ZFS ---"
    if command -v zfs &>/dev/null; then
        msg "GREEN" "ZFS 已安装。"
        zfs version
        return 0
    fi

    msg "YELLOW" "未检测到 ZFS。正在准备安装..."
    
    local arch
    arch=$(dpkg --print-architecture)
    
    if [[ "$arch" == "arm64" ]]; then
        install_zfs_on_arm
    else
        install_zfs_standard
    fi

    if ! command -v zfs &>/dev/null; then
        msg "RED" "ZFS 安装后仍未找到 'zfs' 命令。安装失败。"
        return 1
    fi
    return 0
}

create_zfs_pool_from_file() {
    msg "BLUE" "--- 从镜像文件创建ZFS存储池 ---"
    local default_path="/var/lib/lxd/disks"
    read -p "请输入新的 LXD 存储池名称 (例如: lxd-zfs-pool): " pool_name
    if [[ -z "$pool_name" ]]; then
        msg "RED" "错误: 存储池名称不能为空。"
        return 1
    fi

    read -p "请输入镜像文件大小 (GB): " file_size
    if ! [[ "$file_size" =~ ^[1-9][0-9]*$ ]]; then
        msg "RED" "错误: 大小必须是一个正整数。"
        return 1
    fi

    local image_file_path="${default_path}/${pool_name}.img"
    msg "YELLOW" "将在 '${image_file_path}' 创建一个 ${file_size}GB 的镜像文件。"
    read -p "$(msg "YELLOW" "您确定要继续吗? [y/N]: ")" confirm
    if [[ ! "${confirm}" =~ ^[yY]$ ]]; then
        msg "BLUE" "操作已由用户取消。"
        return
    fi

    if zpool list -H -o name | grep -q "^${pool_name}$"; then
        msg "RED" "错误: 名为 '${pool_name}' 的ZFS池已存在。"
        return 1
    fi

    if [[ -f "$image_file_path" ]]; then
        msg "RED" "错误: 镜像文件 '${image_file_path}' 已存在。"
        return 1
    fi

    msg "BLUE" "步骤 1/4: 创建目录 '${default_path}'..."
    mkdir -p "$default_path"

    msg "BLUE" "步骤 2/4: 创建 ${file_size}GB 的稀疏镜像文件..."
    if ! truncate -s "${file_size}G" "$image_file_path"; then
        msg "RED" "创建镜像文件失败。"
        return 1
    fi
    msg "GREEN" "✓ 镜像文件创建成功。"

    msg "BLUE" "步骤 3/4: 在镜像文件上创建 ZFS 池 '$pool_name'..."
    if ! zpool create -f "$pool_name" "$image_file_path"; then
        msg "RED" "创建 ZFS 池失败。请检查错误信息。"
        return 1
    fi
    msg "GREEN" "✓ ZFS 池创建成功。"
    zpool status "$pool_name"

    msg "BLUE" "\n步骤 4/4: 在 LXD 中创建存储池..."
    if ! lxc storage create "$pool_name" zfs source="$pool_name"; then
        msg "RED" "在 LXD 中创建存储池失败。"
        msg "YELLOW" "您可能需要手动清理: zpool destroy $pool_name; rm ${image_file_path}"
        return 1
    fi
    msg "GREEN" "✓ LXD 存储池创建成功。"
    lxc storage list

    set_lxd_pool_as_default "$pool_name"
    
    msg "GREEN" "==============================================="
    msg "GREEN" "✓ ZFS 存储池配置完成！"
    msg "GREEN" "==============================================="
}

create_zfs_pool_from_device() {
    msg "BLUE" "--- 从块设备创建ZFS存储池 (高级) ---"
    msg "YELLOW" "以下是系统中可用的块设备 (磁盘):"
    lsblk -d -o NAME,SIZE,TYPE | grep 'disk'
    echo ""

    read -p "请输入要用于创建 ZFS 池的设备名称 (例如: sdb, vdb): /dev/" device_name
    local device_path="/dev/${device_name}"

    if [[ -z "$device_name" ]] || [[ ! -b "$device_path" ]]; then
        msg "RED" "错误: 设备 '$device_path' 无效或不存在。"
        return 1
    fi
    
    read -p "请输入新的 LXD 存储池名称 (例如: lxd-zfs-pool): " pool_name
    if [[ -z "$pool_name" ]]; then
        msg "RED" "错误: 存储池名称不能为空。"
        return 1
    fi

    msg "RED" "警告: 此操作将完全擦除设备 '$device_path' 上的所有数据！"
    read -p "$(msg "YELLOW" "您确定要继续吗? [y/N]: ")" confirm
    if [[ ! "${confirm}" =~ ^[yY]$ ]]; then
        msg "BLUE" "操作已由用户取消。"
        return
    fi
    
    msg "BLUE" "步骤 1/2: 创建 ZFS 池 '$pool_name' on '$device_path'..."
    if ! zpool create -f "$pool_name" "$device_path"; then
        msg "RED" "创建 ZFS 池失败。请检查错误信息。"
        zpool status
        return 1
    fi
    msg "GREEN" "✓ ZFS 池创建成功。"
    zpool status "$pool_name"
    
    msg "BLUE" "\n步骤 2/2: 在 LXD 中创建存储池..."
    if ! lxc storage create "$pool_name" zfs source="$pool_name"; then
        msg "RED" "在 LXD 中创建存储池失败。"
        msg "YELLOW" "您可能需要手动清理: zpool destroy $pool_name"
        return 1
    fi
    msg "GREEN" "✓ LXD 存储池创建成功。"
    lxc storage list

    set_lxd_pool_as_default "$pool_name"
    
    msg "GREEN" "==============================================="
    msg "GREEN" "✓ ZFS 存储池配置完成！"
    msg "GREEN" "==============================================="
}

show_zfs_creation_menu() {
    clear
    msg "CYAN" "请选择创建ZFS存储池的方式:"
    echo "  1) 从镜像文件创建 (推荐, 可限制大小)"
    echo "  2) 从专用块设备创建 (将格式化整个磁盘)"
    echo "  3) 返回"
    read -p "请输入选项 [1-3]: " creation_choice
    case "$creation_choice" in
        1) create_zfs_pool_from_file ;;
        2) create_zfs_pool_from_device ;;
        3) return ;;
        *) msg "RED" "无效选项" ;;
    esac
}

manage_zfs_storage() {
    while true; do
        clear
        msg "BLUE" "#############################################"
        msg "BLUE" "#            LXD ZFS 存储管理             #"
        msg "BLUE" "#############################################"
        echo "当前 ZFS 状态:"
        if command -v zfs &>/dev/null; then
            msg "GREEN" "  -> 已安装"
        else
            msg "RED" "  -> 未安装"
        fi
        lxc storage list
        echo "---------------------------------------------"
        echo "请选择要执行的操作:"
        echo "  1) 检查并安装 ZFS"
        echo "  2) 创建新的 LXD ZFS 存储池"
        echo -e "  3) ${COLOR_RED}返回主菜单${COLOR_NC}"
        read -p "请输入选项 [1-3]: " zfs_choice

        case $zfs_choice in
            1) install_zfs ;;
            2) 
                if ! command -v zfs &>/dev/null; then
                    msg "RED" "错误: ZFS 未安装。请先从菜单中选择安装 ZFS。"
                else
                    show_zfs_creation_menu
                fi
                ;;
            3) return ;;
            *)
                msg "RED" "无效的选项 '$zfs_choice'，请重新输入。"
                ;;
        esac
        echo ""
        read -n 1 -s -r -p "按任意键继续..."
    done
}

main_menu() {
    while true; do
        clear
        msg "BLUE" "#############################################"
        msg "BLUE" "#            LXD 助手 (v2.1)              #"
        msg "BLUE" "#############################################"
        echo "请选择要执行的操作:"
        echo -e "  1) ${COLOR_BLUE}安装或检查 LXD 环境${COLOR_NC}"
        echo -e "  2) ${COLOR_GREEN}备份所有 LXD 镜像${COLOR_NC}"
        echo -e "  3) ${COLOR_YELLOW}从备份恢复 LXD 镜像${COLOR_NC}"
        echo -e "  4) ${COLOR_CYAN}管理ZFS储存池${COLOR_NC}"
        echo "  5) 列出本地 LXD 镜像"
        echo -e "  6) ${COLOR_RED}退出脚本${COLOR_NC}"
        read -p "请输入选项 [1-6]: " main_choice

        case $main_choice in
            1) install_lxd ;;
            2) backup_images ;;
            3) restore_images ;;
            4) manage_zfs_storage ;;
            5)
                msg "BLUE" "--- 当前本地LXD镜像列表 ---"
                lxc image list
                ;;
            6)
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
check_dependencies

if ! is_lxd_installed; then
    clear
    msg "RED" "检测到您的系统尚未安装 LXD。"
    read -p "$(msg "YELLOW" "是否立即通过APT安装LXD? [y/N]: ")" install_now
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

main_menu
